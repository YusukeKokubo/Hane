import SwiftUI

/// URLと検索語を兼ねる入力欄。打ちかけのアドレスは、閲覧履歴から続きを補う。
///
/// 補った続きは選択された状態で入るので、そのまま打ち続ければ置き換わり、
/// Return で確定すれば補ったページへ移る。
struct AddressBar: View {
    let tab: Tab
    let store: TabStore

    @State private var text = ""
    @State private var selection: TextSelection?
    /// 最後にこちらから入力欄へ出した文字列。これと違えば利用者が書き換えている。
    @State private var shownText = ""
    /// 利用者が打った部分。補った続きは含めない。
    @State private var typed = ""
    /// 補った候補。入力欄の中身がこれの `text` と同じあいだだけ有効。
    @State private var completion: HistoryCompletion?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("検索語またはURLを入力", text: $text, selection: $selection)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit {
                if let completion = activeCompletion {
                    tab.open(typed: completion.url)
                    show(completion.url)
                } else if let url = tab.open(text) {
                    show(url)
                }
                isFocused = false
            }
            .onExitCommand {
                // 補った続きが出ていれば、まずそれだけを取り消す。
                if activeCompletion != nil {
                    dropCompletion()
                    return
                }
                showCurrentURL()
                isFocused = false
            }
            // タブを切り替えたら、入力途中の文字は捨ててそのタブのURLを出す。
            .onChange(of: tab.id, initial: true) { showCurrentURL() }
            // 書きかけの入力は、ページ側のURL変化で上書きしない。
            .onChange(of: tab.url) { if !isEditing { showCurrentURL() } }
            .onChange(of: store.addressFocusRequest) { isFocused = true }
            .onChange(of: text, initial: true) {
                followEdit()
                mirrorState()
            }
            // 補った候補を確定すると、入力欄の中身は変わらず候補だけが消えるので、こちらでも写す。
            .onChange(of: completion) { mirrorState() }
            .onChange(of: isFocused, initial: true) { store.addressBar.isFocused = isFocused }
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

    private var activeCompletion: HistoryCompletion? {
        completion.flatMap { $0.text == text ? $0 : nil }
    }

    /// 入力欄の中身が変わるたびに呼ぶ。利用者が打ち足したときだけ、続きを補う。
    private func followEdit() {
        // 補った結果や、こちらから出したURLで呼ばれたときは何もしない。
        if text == completion?.text { return }
        if text == shownText {
            typed = ""
            completion = nil
            return
        }
        // 打った部分を消しているとき（補った続きを消したときも含む）は補わない。
        // 補うと、消した文字がすぐに戻ってきてしまう。
        let isDeleting = typed.hasPrefix(text) && text.count <= typed.count
        typed = text
        guard isFocused, !isDeleting, let found = store.history.completion(for: text) else {
            completion = nil
            return
        }
        completion = found
        text = found.text
        let start = found.text.index(found.text.startIndex, offsetBy: typed.count)
        selection = TextSelection(range: start..<found.text.endIndex)
    }

    /// 外部から状態を尋ねられたときのための写し。
    private func mirrorState() {
        store.addressBar.text = text
        store.addressBar.completion = activeCompletion.map { String($0.text.dropFirst(typed.count)) }
    }

    private func dropCompletion() {
        completion = nil
        text = typed
        selection = TextSelection(insertionPoint: typed.endIndex)
    }

    private func showCurrentURL() {
        show(tab.url)
    }

    private func show(_ url: URL?) {
        typed = ""
        completion = nil
        text = url?.absoluteString ?? ""
        shownText = text
    }
}
