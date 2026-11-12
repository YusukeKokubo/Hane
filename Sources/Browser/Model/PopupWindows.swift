import Foundation
import WebKit

/// `window.open` で開こうとした窓を受ける。ページの案内役（`Page` の UI delegate）と小窓から呼ばれる。
///
/// 止めるかどうかは WebKit がその手前で決める（`javaScriptCanOpenWindowsAutomatically`）。
/// 切ってあれば、クリックなどの操作の中から開こうとしたものしかここまで届かない。
///
/// 大きさを指定して開いたもの（ログインの小窓など）は、別の小さな窓（`PopupWindow`）で開いてページへ返す。
/// 開いた側は `window.opener` で小窓とやりとりでき、ログインの結果を受け取れる。大きさの指定がないものは
/// リンクを別に開きたいだけのことが多いので、新しいタブで開き、ページへは窓を返さない（null のまま）。
/// `target="_blank"` のリンクはここを通らず、`Page` の案内役が新しいタブへ振り替える。
@MainActor
enum PopupWindows {
    /// 開いている小窓。閉じると外れる。
    private(set) static var windows: [PopupWindow] = []

    /// そのタブ管理のページが開いた小窓を閉じる。プロファイルを切り替えるとき、前のプロファイルのサイトデータを使う窓を残さないため。
    static func close(openedBy opener: any TabOpening) {
        // 閉じると `windows` から外れるので、写しを回す。
        for window in Array(windows) where window.opener === opener {
            window.close()
        }
    }

    /// 窓を開いてほしいと頼まれた。小窓を作ったときはその Web ビューを返す（WebKit がそこへ読み込む）。
    static func create(
        with configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        features: WKWindowFeatures,
        from webView: WKWebView,
        opener: (any TabOpening)?
    ) -> WKWebView? {
        if features.width != nil || features.height != nil {
            let popup = PopupWindow(
                configuration: configuration, features: features, over: webView.window, opener: opener
            ) { closed in
                windows.removeAll { $0 === closed }
            }
            windows.append(popup)
            return popup.webView
        }
        // 中身を後からスクリプトで書き込む空の窓は、null を返した時点で使えないので開かない。
        guard let url = action.request.url, url.absoluteString != "about:blank" else { return nil }
        opener?.openTab(with: action.request, inBackground: false)
        return nil
    }
}
