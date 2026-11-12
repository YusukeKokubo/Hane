import Foundation
import ObjectiveC
import WebKit

/// `window.open` で開こうとした窓を受ける。
///
/// `WebPage` の中の案内役（UI delegate）は窓を作る手続きを持たないので、そのままでは `window.open` は
/// クリックの中から呼んでも黙って null を返し、何も開かない。その手続きを案内役の型に足して受ける。
/// 止めるかどうかは WebKit がその手前で決める（`javaScriptCanOpenWindowsAutomatically`）。
/// 切ってあれば、クリックなどの操作の中から開こうとしたものしかここまで届かない。
///
/// 大きさを指定して開いたもの（ログインの小窓など）は、別の小さな窓（`PopupWindow`）で開いてページへ返す。
/// 開いた側は `window.opener` で小窓とやりとりでき、ログインの結果を受け取れる。大きさの指定がないものは
/// リンクを別に開きたいだけのことが多いので、新しいタブで開き、ページへは窓を返さない（null のまま）。
/// `target="_blank"` のリンクはここを通らず、`NavigationDecider` が新しいタブへ振り替える。
@MainActor
enum PopupWindows {
    /// 一度だけ足す。ページの Web ビューができる前（`PageFactory` がページを作るとき）に呼ぶ。
    /// WebKit は案内役が手続きを持つかを、案内役を受け取ったときに一度だけ確かめるため。
    static func install() { _ = handler }

    /// この Web ビューで `window.open` を受けられるかを確かめ、受けられなければ利用者向けの文で返す。
    /// 足した手続きは外れても黙って null が返るだけなので、`InternalsCheck` が最初のページでこれを呼んで知らせる。
    static func problem(in webView: WKWebView) -> String? {
        guard let adapter = NSClassFromString(adapterName) else {
            return "window.open を受けられません（案内役の型 \(adapterName) が見つかりません）。ログインの小窓などが開きません"
        }
        // 足せなかったのは WebKit 自身が手続きを持ったからで、窓は WebKit が開いているかもしれない。
        // 壊れたとは言い切れないので、振る舞いを確かめるよう促すだけにする。
        guard let handler else {
            return "WebKit が window.open の窓を自分で開くようになりました。このブラウザの小窓とタブで受ける作りは使われていないので、ログインの小窓などの振る舞いを確かめてください"
        }
        let reason: String? = {
            guard let delegate = webView.uiDelegate else { return "Web ビューに案内役が付いていません" }
            guard delegate.isKind(of: adapter) else { return "案内役の型が \(type(of: delegate)) に変わりました" }
            guard class_getMethodImplementation(object_getClass(delegate), selector) == handler else {
                return "足した手続きが使われていません"
            }
            return nil
        }()
        return reason.map { "window.open を受けられません（\($0)）。ログインの小窓などが開きません" }
    }

    /// ページの受け口（ページごとに一つ）と、そのページから開く窓を受けるタブ管理を結びつける。
    ///
    /// WebKit が窓を開いてほしいと言ってくるときは Web ビューしか渡さないので、その設定の受け口から引く。
    /// 受け口は公開の設定で、`WebPage` が中で作る Web ビューにもそのまま渡る（`popupsFollowTheSetting` のテストで見ている）。
    static func register(_ controller: WKUserContentController, opener: any TabOpening) {
        entries.removeAll { $0.controller == nil }
        entries.append(Entry(controller: controller, opener: opener))
    }

    /// 開いている小窓。閉じると外れる。
    private(set) static var windows: [PopupWindow] = []

    /// そのタブ管理のページが開いた小窓を閉じる。プロファイルを切り替えるとき、前のプロファイルのサイトデータを使う窓を残さないため。
    static func close(openedBy opener: any TabOpening) {
        // 閉じると `windows` から外れるので、写しを回す。
        for window in Array(windows) where window.opener === opener {
            window.close()
        }
    }

    private struct Entry {
        weak var controller: WKUserContentController?
        weak var opener: (any TabOpening)?
    }

    private static var entries: [Entry] = []

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

    private static func opener(of webView: WKWebView) -> (any TabOpening)? {
        let controller = webView.configuration.userContentController
        return entries.first { $0.controller === controller }?.opener
    }

    /// WebPage が Web ビューに付ける案内役の型。
    private static let adapterName = "WebKit.WKUIDelegateAdapter"
    private static let selector = #selector(WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:))

    /// 案内役の型に足した手続き。足せなかったときは `nil`（窓は開かないまま）。
    private static let handler: IMP? = {
        // 名前が変わったら何もしない。
        guard let adapter = NSClassFromString(adapterName) else { return nil }
        let create: @convention(block) (AnyObject, WKWebView, WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures)
            -> WKWebView? = { _, webView, configuration, action, features in
                MainActor.assumeIsolated {
                    Self.create(with: configuration, for: action, features: features, from: webView, opener: opener(of: webView))
                }
            }
        let implementation = imp_implementationWithBlock(create)
        // 返り値と引数4つがオブジェクトの手続き。WebKit 自身が持つようになっていれば足さない（false が返る）。
        guard class_addMethod(adapter, selector, implementation, "@@:@@@@") else {
            imp_removeBlock(implementation)
            return nil
        }
        return implementation
    }()
}
