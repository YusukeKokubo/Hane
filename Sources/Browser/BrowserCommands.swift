import AppKit
import SwiftUI

/// メニューとキーボードショートカット。
struct BrowserCommands: Commands {
    let store: TabStore

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        // 標準の「閉じる」（Cmd+W）より前に置くことで、Cmd+W をタブ側で受ける。
        CommandGroup(replacing: .newItem) {
            Button("新規タブ") { store.newTab() }
                .keyboardShortcut("t")
            Button("タブを閉じる") { closeTab() }
                .keyboardShortcut("w")
            Divider()
            Button("場所を開く…") { store.focusAddressBar() }
                .keyboardShortcut("l")
        }

        CommandMenu("移動") {
            Button("戻る") { store.selected?.goBack() }
                .keyboardShortcut("[")
                .disabled(store.selected?.canGoBack != true)
            Button("進む") { store.selected?.goForward() }
                .keyboardShortcut("]")
                .disabled(store.selected?.canGoForward != true)
            Divider()
            Button("ページを再読み込み") { store.selected?.reload() }
                .keyboardShortcut("r")
                .disabled(store.selected?.hasContent != true)
            Button("読み込みを中止") { store.selected?.stop() }
                .keyboardShortcut(".")
                .disabled(store.selected?.page.isLoading != true)
            Divider()
            Button("次のタブ") { store.select(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("前のタブ") { store.select(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "最後のタブ" : "タブ \(number)") { store.select(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }

        // バーと同じものを、キーボードやメニューからも選べるようにする。
        CommandMenu("ブックマーク") {
            Button(hasBookmarkForSelectedPage ? "ブックマークを編集…" : "ブックマークを追加…") {
                store.requestBookmarkEditor()
            }
            .keyboardShortcut("d")
            .disabled(store.selected?.url == nil)
            // バーのフォルダの一覧を開く。⌘1〜9 はタブの切り替えに使っているので ⌃ にする。
            // キーそのものは FolderShortcut が拾う。ここはどのキーで開くかを見せるため。
            if !store.bookmarks.folders.isEmpty {
                Divider()
                Section("フォルダの一覧を開く") {
                    ForEach(Array(store.bookmarks.folders.prefix(9).enumerated()), id: \.element.id) { index, folder in
                        Button(folder.name) { store.toggleFolder(number: index + 1) }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                    }
                }
            }
            if !store.bookmarks.items.isEmpty {
                Divider()
            }
            ForEach(store.bookmarks.items) { item in
                switch item {
                case .bookmark(let bookmark):
                    Button(bookmark.title) { store.activate(bookmark: bookmark.id) }
                case .folder(let folder):
                    Menu {
                        ForEach(folder.bookmarks) { bookmark in
                            Button(bookmark.title) { store.activate(bookmark: bookmark.id) }
                        }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
            }
        }
    }

    private var hasBookmarkForSelectedPage: Bool {
        store.selected.flatMap(store.bookmark(for:)) != nil
    }

    private func closeTab() {
        if !store.closeSelected() {
            dismissWindow(id: BrowserApp.windowID)
        }
    }
}

/// ⌃1〜9 で、バーで左から N 番目のフォルダの一覧を開け閉めする。
///
/// メニューにも同じ項目を出しているが、SwiftUI はメニューの中身を開く直前まで作らないため、
/// 起動後に足したフォルダのショートカットは、メニューを一度開くまで効かない。
/// そのため AppKit の局所モニタでキーを先に拾う。WebView にフォーカスがあっても届く。
@MainActor
enum FolderShortcut {
    static func install(store: TabStore) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handle(event, store: store) }
            // そのフォルダがなければ、ページなど本来の受け手へそのまま流す。
            return handled ? nil : event
        }
    }

    /// ⌃N なら N 番目のフォルダの一覧を開け閉めして true を返す。
    static func handle(_ event: NSEvent, store: TabStore) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
              let number = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
              (1...9).contains(number), number <= store.bookmarks.folders.count
        else { return false }
        store.toggleFolder(number: number)
        return true
    }
}
