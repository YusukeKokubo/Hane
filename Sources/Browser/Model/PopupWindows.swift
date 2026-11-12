import Foundation
import ObjectiveC
import WebKit

/// `window.open` で開こうとした窓を、新しいタブで開く。
///
/// `WebPage` の中の案内役（UI delegate）は窓を作る手続きを持たないので、そのままでは `window.open` は
/// クリックの中から呼んでも黙って null を返し、何も開かない。その手続きを案内役の型に足して、頼まれたアドレスを
/// 新しいタブで開く。止めるかどうかは WebKit がその手前で決める（`javaScriptCanOpenWindowsAutomatically`）。
/// 切ってあれば、クリックなどの操作の中から開こうとしたものしかここまで届かない。
///
/// ページへは窓を返さない（null のまま）。開いた窓を後から操るページ（ログインの小窓など）は思いどおりには動かない。
/// `target="_blank"` のリンクはここを通らず、`NavigationDecider` が新しいタブへ振り替える。
@MainActor
enum PopupWindows {
    /// 一度だけ足す。ページの Web ビューができる前（`PageFactory` がページを作るとき）に呼ぶ。
    /// WebKit は案内役が手続きを持つかを、案内役を受け取ったときに一度だけ確かめるため。
    static func install() { _ = installed }

    /// ページと、そのページから開く窓を受けるタブ管理を結びつける。
    static func register(_ page: WebPage, opener: any TabOpening) {
        entries.removeAll { $0.page == nil }
        entries.append(Entry(page: page, opener: opener))
    }

    private struct Entry {
        weak var page: WebPage?
        weak var opener: (any TabOpening)?
    }

    private static var entries: [Entry] = []

    private static func open(_ request: URLRequest, from webView: WKWebView) {
        // 中身を後からスクリプトで書き込む空の窓は、null を返した時点で使えないので開かない。
        guard let url = request.url, url.absoluteString != "about:blank",
              let entry = entries.first(where: { $0.page.flatMap(PageProcess.webView(of:)) === webView })
        else { return }
        entry.opener?.openTab(with: request, inBackground: false)
    }

    private static let installed: Bool = {
        // WebPage が Web ビューに付ける案内役の型。名前が変わったら何もしない（窓は開かないまま）。
        guard let adapter = NSClassFromString("WebKit.WKUIDelegateAdapter") else { return false }
        let selector = #selector(WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:))
        let create: @convention(block) (AnyObject, WKWebView, WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures)
            -> WKWebView? = { _, webView, _, action, _ in
                MainActor.assumeIsolated { open(action.request, from: webView) }
                return nil
            }
        // 返り値と引数4つがオブジェクトの手続き。WebKit 自身が持つようになっていれば足さない（false が返る）。
        return class_addMethod(adapter, selector, imp_implementationWithBlock(create), "@@:@@@@")
    }()
}
