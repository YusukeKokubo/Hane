import SwiftUI

/// バーの左側に並ぶブックマーク。
struct BookmarkStrip: View {
    let store: TabStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.bookmarks.bookmarks) { bookmark in
                BookmarkChip(store: store, bookmark: bookmark)
            }
            // 末尾への落とし先を兼ねる仕切り。ブックマークがまだなくても、ここへタブを落とせば最初の1件になる。
            Group {
                if store.bookmarks.bookmarks.isEmpty {
                    Color.clear.frame(width: 10)
                } else {
                    Divider().padding(.horizontal, 6)
                }
            }
            .frame(height: 22)
            .contentShape(.rect)
            .barDropTarget { store.drop($0, before: nil) }
        }
    }
}

private struct BookmarkChip: View {
    let store: TabStore
    let bookmark: Bookmark

    @State private var isHovered = false
    @State private var isEditing = false

    var body: some View {
        let tab = store.bookmarkTabs[bookmark.id]
        let awayTitle = store.awayTitle(for: bookmark)

        // Chrome や Arc の固定タブと同じく、アイコンだけで場所を取らない。名前は指したときの説明に回す。
        Favicon(image: store.favicons.image(for: bookmark.url))
            .overlay(alignment: .topTrailing) {
                // ブックマークのアドレスから離れていることだけは、アイコンの上で分かるようにする。
                if awayTitle != nil {
                    Circle().fill(.tint).frame(width: 5, height: 5).offset(x: 3, y: -2)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
        .barItemBackground(state(of: tab), isHovered: isHovered)
        .overlay(alignment: .bottom) {
            if let tab, tab.isLoading { LoadingLine(progress: tab.estimatedProgress) }
        }
        .contentShape(.rect)
        .onTapGesture { store.activate(bookmark: bookmark.id) }
        .onHover { isHovered = $0 }
        .help(awayTitle.map { "\(bookmark.title) / \($0)" } ?? bookmark.title)
        .contextMenu { BookmarkActions(store: store, bookmark: bookmark) { isEditing = true } }
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            BookmarkEditor(store: store, target: .bookmark(bookmark.id))
        }
        .draggable(BarDragItem.bookmark(bookmark.id))
        .barDropTarget { store.drop($0, before: bookmark.id) }
        // タブとブックマークを、VoiceOver や hanectl の ui-snapshot から見分けられるようにする。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bookmark.title)
        .accessibilityIdentifier("bookmark")
    }

    private func state(of tab: Tab?) -> BarItemState {
        guard let tab else { return .idle }
        return tab.id == store.selectedID ? .selected : .live
    }
}

/// ブックマークを右クリックしたときの操作。
private struct BookmarkActions: View {
    let store: TabStore
    let bookmark: Bookmark
    let edit: () -> Void

    var body: some View {
        let tab = store.bookmarkTabs[bookmark.id]
        let isAway = store.awayTitle(for: bookmark) != nil
        Button("名前を編集…", action: edit)
        // バーはアイコンだけで戻すボタンを置かないので、戻す手はここに出す。
        Button("\(bookmark.url.host() ?? bookmark.title) に戻す") { store.returnToBookmark(bookmark.id) }
            .disabled(!isAway)
        Button("アドレスを今のページにする") { store.updateBookmarkToCurrentPage(bookmark.id) }
            .disabled(!isAway)
        Divider()
        Button("ページを閉じる") { if let tab { store.close(tab.id) } }
            .disabled(tab == nil)
        Divider()
        // 開いているページは消さずに普通のタブへ戻る（`removeBookmark`）ので、そのときは固定を外すと言う。
        Button(tab == nil ? "削除" : "固定を外す") { store.removeBookmark(bookmark.id) }
    }
}

// MARK: 追加と編集

/// アドレスバーの星。押すか Cmd+D で、追加または編集の画面を出す。
struct BookmarkStarButton: View {
    let tab: Tab
    let store: TabStore

    @State private var isEditing = false

    var body: some View {
        let existing = store.bookmark(for: tab)
        Button(
            existing == nil ? "ブックマークに追加" : "ブックマークを編集",
            systemImage: existing == nil ? "star" : "star.fill"
        ) {
            isEditing = true
        }
        .foregroundStyle(existing == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        .disabled(tab.url == nil)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            BookmarkEditor(store: store, target: existing.map { .bookmark($0.id) } ?? .page(tab.id))
        }
        .onChange(of: store.bookmarkEditorRequest) {
            if tab.url != nil { isEditing = true }
        }
    }
}

struct BookmarkEditor: View {
    enum Target {
        /// 普通のタブのページを、新しいブックマークにする。
        case page(Tab.ID)
        case bookmark(UUID)
    }

    let store: TabStore
    let target: Target

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "ブックマークを編集" : "ブックマークを追加").font(.headline)
                Text(address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Form {
                TextField("名前:", text: $name)
                    // フォームの中では見出しが別の部品になり、欄そのものは名前を持たないので付ける。
                    .accessibilityLabel("名前")
            }
            HStack {
                if case .bookmark(let id) = target {
                    Button("削除", role: .destructive) {
                        store.removeBookmark(id)
                        dismiss()
                    }
                }
                Spacer()
                if !isEditing {
                    Button("キャンセル", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(isEditing ? "完了" : "追加") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear(perform: load)
    }

    private var isEditing: Bool {
        if case .bookmark = target { true } else { false }
    }

    private var address: String {
        switch target {
        case .page(let id): store.tabs.first { $0.id == id }?.url?.absoluteString ?? ""
        case .bookmark(let id): store.bookmarks.bookmark(id)?.url.absoluteString ?? ""
        }
    }

    private func load() {
        switch target {
        case .page(let id):
            name = store.tabs.first { $0.id == id }?.title ?? ""
        case .bookmark(let id):
            name = store.bookmarks.bookmark(id)?.title ?? ""
        }
    }

    private func save() {
        switch target {
        case .page(let id): store.pin(id, title: name)
        case .bookmark(let id): store.bookmarks.rename(id, to: name)
        }
        dismiss()
    }
}
