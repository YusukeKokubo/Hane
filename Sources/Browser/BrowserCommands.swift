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
            .disabled(store.selected?.page.url == nil)
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
