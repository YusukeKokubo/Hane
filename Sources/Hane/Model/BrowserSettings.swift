import Foundation

/// アプリ全体の固定設定。変えたい値はここに集める。
enum BrowserSettings {
    /// アドレスバーにURLでない文字列が入ったときの検索先。
    static let searchEndpoint = "https://www.google.com/search"
    static let searchQueryName = "q"

    /// サイト側にSafari相当として扱ってもらうためのUser-Agent末尾。
    static let userAgentSuffix = "Version/26.0 Safari/605.1.15"

    /// 画面から外れてこれだけ経ったタブは、次に選択が変わったときに眠らせてページのプロセスを返す（秒）。
    /// 起こすと履歴ごと戻るが、ページの中の状態（書きかけの入力など）は読み込み直しで消える。
    static let tabSleepDelay: TimeInterval = 30 * 60
}
