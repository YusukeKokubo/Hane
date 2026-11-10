import Foundation

/// アプリ全体の固定設定。変えたい値はここに集める。
enum BrowserSettings {
    /// アドレスバーにURLでない文字列が入ったときの検索先。
    static let searchEndpoint = "https://www.google.com/search"
    static let searchQueryName = "q"

    /// サイト側にSafari相当として扱ってもらうためのUser-Agent末尾。
    static let userAgentSuffix = "Version/26.0 Safari/605.1.15"
}
