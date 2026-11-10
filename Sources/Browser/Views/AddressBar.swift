import SwiftUI

/// URLと検索語を兼ねる入力欄。
struct AddressBar: View {
    let tab: Tab
    let store: TabStore

    @State private var text = ""
    /// 最後にこちらから入力欄へ出した文字列。これと違えば利用者が書き換えている。
    @State private var shownText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("検索語またはURLを入力", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit {
                if let url = tab.open(text) { show(url) }
                isFocused = false
            }
            .onExitCommand {
                showCurrentURL()
                isFocused = false
            }
            // タブを切り替えたら、入力途中の文字は捨ててそのタブのURLを出す。
            .onChange(of: tab.id, initial: true) { showCurrentURL() }
            // 書きかけの入力は、ページ側のURL変化で上書きしない。
            .onChange(of: tab.page.url) { if !isEditing { showCurrentURL() } }
            .onChange(of: store.addressFocusRequest) { isFocused = true }
            .onChange(of: text, initial: true) { store.addressBar.text = text }
            .onChange(of: isFocused, initial: true) { store.addressBar.isFocused = isFocused }
            // 起動直後は、ウインドウが前面に出てからでないとフォーカスが入らない。
            // 起動直後はウインドウが前面に出るまでフォーカスが入らず、要求は黙って捨てられる。
            // 入ったことを確かめられるまで、短い間だけやり直す。
            .task {
                for _ in 0..<20 where !isFocused {
                    isFocused = true
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
    }

    private var isEditing: Bool {
        isFocused && text != shownText
    }

    private func showCurrentURL() {
        show(tab.page.url)
    }

    private func show(_ url: URL?) {
        text = url?.absoluteString ?? ""
        shownText = text
    }
}
