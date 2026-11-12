import AppKit
import WebKit

/// ログインの小窓のように、大きさを指定して `window.open` された窓。
///
/// 開いたページへ窓を返さないと `window.opener` がつながらず、小窓で済ませたログインの結果を元のページへ返せない
/// （Google などのログインの小窓は、窓が返らないと「開けなかった」として止まる）。返す Web ビューは WebKit が渡した設定で
/// 作らなければならず、`WebPage` はそれを受け取る口を持たない。そのためここだけ AppKit の窓に `WKWebView` を直に置く。
/// 窓は閉じるまでのあいだだけあり、常に動く処理は持たない。
@MainActor
final class PopupWindow: NSObject, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    /// 小窓の中から大きさを指定せずに開いたものを、タブで開いてもらう先。
    private weak var opener: (any TabOpening)?
    private var observations: [NSKeyValueObservation] = []
    private let onClose: (PopupWindow) -> Void

    init(
        configuration: WKWebViewConfiguration,
        features: WKWindowFeatures,
        over parent: NSWindow?,
        opener: (any TabOpening)?,
        onClose: @escaping (PopupWindow) -> Void
    ) {
        let size = NSSize(width: features.width?.doubleValue ?? 500, height: features.height?.doubleValue ?? 600)
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        self.opener = opener
        self.onClose = onClose
        super.init()

        webView.uiDelegate = self
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        // どのサイトの小窓かを見せる。ログインの小窓なので、行き先が分かるようにしておく。
        observations = [
            webView.observe(\.title, options: [.initial]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateTitle() }
            },
            webView.observe(\.url, options: [.initial]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateTitle() }
            },
        ]
        show(over: parent)
    }

    /// 開いたタブの窓の真ん中に出す。アプリが裏にいるときは、その窓のすぐ上に重ねるだけにして、
    /// ほかのアプリの窓より前には出さない。開いたページが窓の中にない（テスト）ときは出さない。
    private func show(over parent: NSWindow?) {
        guard let parent else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2))
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.order(.above, relativeTo: parent.windowNumber)
        }
    }

    private func updateTitle() {
        window.title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? "ポップアップ"
        window.subtitle = webView.url?.host() ?? ""
    }

    func close() {
        window.close()
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        PopupWindows.create(with: configuration, for: navigationAction, features: windowFeatures, from: webView, opener: opener)
    }

    /// ページが `window.close()` を呼んだ。ログインが済むと小窓は自分で閉じる。
    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        observations = []
        webView.uiDelegate = nil
        // 閉じた窓は AppKit がしばらく掴んでいることがあり、中に置いたままだと Web ビューごとページが残る
        // （開いた側からは window.closed が false のままに見える）。窓から外して、ここで手放す。
        window.contentView = nil
        onClose(self)
    }
}
