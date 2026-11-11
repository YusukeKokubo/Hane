import Foundation
import WebKit

/// ページを描いているプロセス（WebContent）の番号を引く。どのタブがメモリや CPU を使っているかを
/// 測るための開発用で、ページの動作には使わない。
///
/// `WebPage` はプロセス番号を公開していないので、中に持っている Web ビュー（`WKWebView` の仲間）を
/// 実行時に探し、その非公開の `_webProcessIdentifier` を読む。WebKit の中身が変われば `nil` を返すだけで、
/// 落ちはしない。`pageProcessIsFound` のテストが、引けなくなったことを知らせる。
@MainActor
enum PageProcess {
    /// まだ Web ビューを作っていないページ（読み込む前のタブ）では `nil`。ここで作らせはしない。
    static func identifier(of page: WebPage) -> pid_t? {
        guard let view = webView(of: page),
              view.responds(to: selector),
              let pid = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
              pid > 0
        else { return nil }
        return pid
    }

    /// ページが中に持っている Web ビュー。まだ作っていなければ `nil`（ここで作らせはしない）。
    static func webView(of page: WebPage) -> WKWebView? {
        // 遅れて作る Web ビューの置き場は Optional なので、中身があるときだけ子が一つ見える。
        guard let stored = Mirror(reflecting: page).children.first(where: { $0.label == "$__lazy_storage_$_backingWebView" })
        else { return nil }
        return Mirror(reflecting: stored.value).children.first?.value as? WKWebView
    }

    private static let selector = NSSelectorFromString("_webProcessIdentifier")
}
