import Foundation
import WebKit

/// ページを描いているプロセス（WebContent）の番号を引く。どのタブがメモリや CPU を使っているかを
/// 測るための開発用。普段の動作はこれに頼らない（WebKit の中身が変わっても、測れなくなるだけで済むように）。
///
/// プロセス番号は公開されていないので、Web ビューの非公開の `_webProcessIdentifier` を読む。
/// WebKit の中身が変われば `nil` を返すだけで、落ちはしない。`pageProcessIsFound` のテストが、引けなくなったことを知らせる。
@MainActor
enum PageProcess {
    /// まだ何も読み込んでいないページでは `nil`。
    static func identifier(of page: Page) -> pid_t? {
        guard page.webView.responds(to: selector),
              let pid = (page.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
              pid > 0
        else { return nil }
        return pid
    }

    private static let selector = NSSelectorFromString("_webProcessIdentifier")
}
