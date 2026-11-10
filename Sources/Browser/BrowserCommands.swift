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
    }

    private func closeTab() {
        if !store.closeSelected() {
            dismissWindow(id: BrowserApp.windowID)
        }
    }
}
