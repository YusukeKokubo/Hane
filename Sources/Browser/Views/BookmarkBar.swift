import SwiftUI

/// バーの左側に並ぶブックマークとフォルダ。
struct BookmarkStrip: View {
    let store: TabStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.bookmarks.items) { item in
                switch item {
                case .bookmark(let bookmark):
                    BookmarkChip(store: store, bookmark: bookmark)
                case .folder(let folder):
                    FolderChip(store: store, folder: folder)
                }
            }
            // 末尾への落とし先を兼ねる仕切り。ブックマークがまだなくても、ここへタブを落とせば最初の1件になる。
            Group {
                if store.bookmarks.items.isEmpty {
                    Color.clear.frame(width: 10)
                } else {
                    Divider().padding(.horizontal, 6)
                }
            }
            .frame(height: 22)
            .contentShape(.rect)
            .barDropTarget(.leading) { store.drop($0, into: nil, before: nil) }
        }
    }
}

// MARK: 一段目のブックマーク

private struct BookmarkChip: View {
    let store: TabStore
    let bookmark: Bookmark

    @State private var isHovered = false
    @State private var isEditing = false

    var body: some View {
        let tab = store.bookmarkTabs[bookmark.id]
        let awayTitle = store.awayTitle(for: bookmark)

        HStack(spacing: 6) {
            Text(bookmark.title)
            if let awayTitle {
                Text("/").foregroundStyle(.tertiary)
                Text(awayTitle)
                    .truncationMode(.tail)
                    .frame(maxWidth: 170, alignment: .leading)
                ReturnButton(store: store, bookmark: bookmark)
            }
        }
        .lineLimit(1)
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, awayTitle == nil ? 10 : 4)
        .frame(height: 26)
        .barItemBackground(state(of: tab), isHovered: isHovered)
        .overlay(alignment: .bottom) {
            if let tab, tab.page.isLoading { LoadingLine(progress: tab.page.estimatedProgress) }
        }
        .contentShape(.rect)
        .onTapGesture { store.activate(bookmark: bookmark.id) }
        .onHover { isHovered = $0 }
        .help(bookmark.url.absoluteString)
        .contextMenu { BookmarkActions(store: store, bookmark: bookmark) { isEditing = true } }
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            BookmarkEditor(store: store, target: .bookmark(bookmark.id))
        }
        .draggable(BarDragItem.bookmark(bookmark.id))
        .barDropTarget(.leading) { store.drop($0, into: nil, before: bookmark.id) }
        // タブとブックマークとフォルダを、VoiceOver や browserctl の ui-snapshot から見分けられるようにする。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bookmark.title)
        .accessibilityIdentifier("bookmark")
    }

    private func state(of tab: Tab?) -> BarItemState {
        guard let tab else { return .idle }
        return tab.id == store.selectedID ? .selected : .live
    }
}

/// ブックマークから開いたページを、ブックマークのアドレスへ戻すボタン。
private struct ReturnButton: View {
    let store: TabStore
    let bookmark: Bookmark

    var body: some View {
        let label = "\(bookmark.url.host() ?? bookmark.title) に戻す"
        Button(label, systemImage: "arrow.uturn.backward") { store.returnToBookmark(bookmark.id) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(label)
    }
}

/// ブックマークを右クリックしたときの操作。バーとフォルダの一覧で共通。
private struct BookmarkActions: View {
    let store: TabStore
    let bookmark: Bookmark
    let edit: () -> Void

    var body: some View {
        let tab = store.bookmarkTabs[bookmark.id]
        Button("名前とフォルダを編集…", action: edit)
        Button("アドレスを今のページにする") { store.updateBookmarkToCurrentPage(bookmark.id) }
            .disabled(store.awayTitle(for: bookmark) == nil)
        Divider()
        Button("ページを閉じる") { if let tab { store.close(tab.id) } }
            .disabled(tab == nil)
        Divider()
        Button("削除") { store.removeBookmark(bookmark.id) }
    }
}

// MARK: フォルダ

private struct FolderChip: View {
    let store: TabStore
    let folder: BookmarkFolder

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false
    @State private var newName = ""

    var body: some View {
        // 中のページを見ているときは、どのページかをフォルダ名の後ろに出す。
        let selected = folder.bookmarks.first { store.bookmarkTabs[$0.id]?.id == store.selectedID }
        let hasLivePage = folder.bookmarks.contains { store.bookmarkTabs[$0.id] != nil }
        let isOpen = store.openFolder?.id == folder.id

        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.tint)
            Text(folder.name)
            if let selected {
                Text("›").foregroundStyle(.tertiary)
                Text(store.awayTitle(for: selected) ?? selected.title)
                    .truncationMode(.tail)
                    .frame(maxWidth: 170, alignment: .leading)
            }
            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .barItemBackground(selected != nil ? .selected : (hasLivePage ? .live : .idle), isHovered: isHovered)
        .contentShape(.rect)
        .onTapGesture { store.toggleFolder(folder.id) }
        .onHover { isHovered = $0 }
        .popover(isPresented: Binding(
            get: { isOpen },
            set: { if !$0 { store.closeFolder(folder.id) } }
        ), arrowEdge: .bottom) {
            FolderPanel(store: store, folderID: folder.id)
        }
        .contextMenu {
            Button("名前を変更…") {
                newName = folder.name
                isRenaming = true
            }
            Button("削除…") {
                if folder.bookmarks.isEmpty {
                    store.removeBookmark(folder.id)
                } else {
                    isConfirmingDelete = true
                }
            }
        }
        .alert("フォルダの名前を変更", isPresented: $isRenaming) {
            TextField("名前", text: $newName)
            Button("変更") { store.bookmarks.rename(folder.id, to: newName) }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("フォルダ「\(folder.name)」を削除しますか？", isPresented: $isConfirmingDelete) {
            Button("削除", role: .destructive) { store.removeBookmark(folder.id) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("中にある\(folder.bookmarks.count)件のブックマークも一緒に削除されます。開いているページはタブとして残ります。")
        }
        .draggable(BarDragItem.bookmark(folder.id))
        .barDropTarget(.highlight) { store.drop($0, into: folder.id, before: nil) }
        // タブとブックマークとフォルダを、VoiceOver や browserctl の ui-snapshot から見分けられるようにする。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(folder.name)
        .accessibilityIdentifier("folder")
    }
}

/// フォルダを押したときに下へ出す一覧。矢印キーで行を選び、Return か数字キーで開く。
private struct FolderPanel: View {
    let store: TabStore
    let folderID: UUID

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let folder = store.bookmarks.folder(folderID) {
                if folder.bookmarks.isEmpty {
                    Text("ブックマークはありません。タブをここへドラッグすると入ります。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .barDropTarget(.highlight) { store.drop($0, into: folderID, before: nil) }
                }
                ForEach(Array(folder.bookmarks.enumerated()), id: \.element.id) { index, bookmark in
                    FolderRow(store: store, folderID: folderID, bookmark: bookmark, index: index)
                }
            }
        }
        .padding(6)
        .frame(width: 300)
        // 文字入力の欄がないので、キーを受けるには一覧そのものにフォーカスを持たせる。
        // .edit にしておくと、システム設定の「キーボードナビゲーション」が切ってあってもフォーカスが入る。
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) {
            store.moveFolderHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            store.moveFolderHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            store.activateFolderRow()
            return .handled
        }
        .onKeyPress(.escape) {
            store.closeFolder(folderID)
            return .handled
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard press.modifiers.isEmpty, let number = Int(press.characters), (1...9).contains(number) else {
                return .ignored
            }
            store.activateFolderRow(number - 1)
            return .handled
        }
    }
}

private struct FolderRow: View {
    let store: TabStore
    let folderID: UUID
    let bookmark: Bookmark
    let index: Int

    @State private var isEditing = false

    var body: some View {
        let tab = store.bookmarkTabs[bookmark.id]
        let awayTitle = store.awayTitle(for: bookmark)

        HStack(spacing: 6) {
            Text(awayTitle.map { "\(bookmark.title) / \($0)" } ?? bookmark.title)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if awayTitle != nil {
                ReturnButton(store: store, bookmark: bookmark)
            }
            if let tab {
                Button("ページを閉じる", systemImage: "xmark") { store.close(tab.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
        .barItemBackground(tab == nil ? .idle : (tab?.id == store.selectedID ? .selected : .live), isHovered: false)
        // キーボードとマウスで同じ行を指すよう、メニューと同じく選択の当たりを一つにまとめる。
        .background {
            if store.openFolder?.highlighted == index {
                RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.2))
            }
        }
        .contentShape(.rect)
        .onTapGesture { store.activateFolderRow(index) }
        .onHover { if $0 { store.highlightFolderRow(index) } }
        .help(bookmark.url.absoluteString)
        .contextMenu { BookmarkActions(store: store, bookmark: bookmark) { isEditing = true } }
        .popover(isPresented: $isEditing, arrowEdge: .trailing) {
            BookmarkEditor(store: store, target: .bookmark(bookmark.id))
        }
        .draggable(BarDragItem.bookmark(bookmark.id))
        .barDropTarget(.top) { store.drop($0, into: folderID, before: bookmark.id) }
        // タブとブックマークとフォルダを、VoiceOver や browserctl の ui-snapshot から見分けられるようにする。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bookmark.title)
        .accessibilityIdentifier("bookmark")
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
    @State private var folderChoice = FolderChoice.none
    @State private var newFolderName = ""

    private enum FolderChoice: Hashable {
        case none
        case folder(UUID)
        case new
    }

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
                Picker("フォルダ:", selection: $folderChoice) {
                    Text("なし（いちばん上）").tag(FolderChoice.none)
                    if !store.bookmarks.folders.isEmpty {
                        Divider()
                        ForEach(store.bookmarks.folders) { folder in
                            Text(folder.name).tag(FolderChoice.folder(folder.id))
                        }
                    }
                    Divider()
                    Text("新しいフォルダ…").tag(FolderChoice.new)
                }
                if folderChoice == .new {
                    TextField("フォルダ名:", text: $newFolderName)
                }
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
            folderChoice = store.bookmarks.folderID(containing: id).map { .folder($0) } ?? .none
        }
    }

    private func save() {
        let folderID: UUID? = switch folderChoice {
        case .none: nil
        case .folder(let id): id
        case .new: store.bookmarks.addFolder(named: newFolderName).id
        }
        switch target {
        case .page(let id):
            store.pin(id, title: name, folder: folderID)
        case .bookmark(let id):
            store.bookmarks.rename(id, to: name)
            if store.bookmarks.folderID(containing: id) != folderID {
                store.bookmarks.move(id, into: folderID)
            }
        }
        dismiss()
    }
}
