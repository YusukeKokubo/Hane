import AppKit
import Observation
import WebKit

/// ページ側から新しいタブを開いてもらうための窓口。
@MainActor
protocol TabOpening: AnyObject {
    func openTab(with request: URLRequest, inBackground: Bool)
}

/// タブが今読み込んでいるページ。`WKWebView` を一つ持ち、画面と操作に要る値を Observable にして見せる。
///
/// `WebPage` を使わないのは、足りない所を埋めるのに WebKit の中を差し替える裏技が要ったため
/// （プロセスプールと環境設定の共有、`window.open` の受け口）。`WKWebView` ならどれも公開の API で済み、
/// 戻る・進むの履歴を書き出して戻せる（`interactionState`）ので、タブを眠らせても履歴を失わない。
///
/// ページを手放すと Web ビューごとページのプロセスも返る。いつ手放すかは `Tab` が決める。
@MainActor
@Observable
final class Page {
    /// 読み込みの節目。`Tab` が履歴の記録や失敗の表示に使う。
    enum Event {
        case started, committed, finished
        /// ページの題名が変わった。空の題名では知らせない。
        case titleChanged(String)
        /// 失敗の文言。利用者による中断のように見せなくてよい失敗なら `nil`。
        case failed(String?)
    }

    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let delegate: Delegate
    @ObservationIgnored private let onEvent: @MainActor (Event) -> Void
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// `opener` は、このページから新しいタブや小窓を開くときに頼む先。弱く持つので循環しない。
    init(configuration: WKWebViewConfiguration, opener: (any TabOpening)?, log: PageLog, onEvent: @escaping @MainActor (Event) -> Void) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.onEvent = onEvent
        delegate = Delegate(opener: opener, onEvent: onEvent)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        PageLog.route(from: webView, to: log)
        observe()
    }

    // MARK: 操作

    func load(_ request: URLRequest) {
        webView.load(request)
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    /// 戻る・進むの履歴と今の位置の控え。眠らせるときと閲覧状態の保存に使う。中身は WebKit だけが読める。
    var interactionState: Data? {
        webView.interactionState as? Data
    }

    /// 控えから履歴を戻し、そのとき開いていたページを読み込む。戻せなければ `false`
    /// （WebKit の版が変わって控えを読めないときなど。そのときは呼んだ側がアドレスから読み込む）。
    func restore(_ state: Data) -> Bool {
        webView.interactionState = state
        return webView.backForwardList.currentItem != nil
    }

    /// 眠らせると困る最中か。音や動画を流している、カメラやマイクを使っている。
    func isBusy() async -> Bool {
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        return await webView.requestMediaPlaybackState() == .playing
    }

    func callJavaScript(_ body: String, arguments: [String: Any], contentWorld: WKContentWorld) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: contentWorld)
    }

    /// 画面に出ている範囲を PNG にする。`fullPage` なら、画面の外も含めたページ全体を撮る。
    func snapshot(fullPage: Bool) async throws -> Data {
        guard fullPage else {
            return try Self.png(from: try await webView.takeSnapshot(configuration: nil))
        }
        // macOS の takeSnapshot は画面に見えている所しか描かず、外は白くなる。PDF ならページ全体を描くので、それを画像に直す。
        let pdf = try await webView.pdf(configuration: WKPDFConfiguration())
        guard let page = NSPDFImageRep(data: pdf) else { throw CocoaError(.fileReadCorruptFile) }
        let scale = webView.window?.backingScaleFactor ?? 2
        let size = page.bounds.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        page.draw(in: NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    private static func png(from image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    /// 手放す前に呼ぶ。見張りと案内役を外し、読み込みを打ち切る。
    func tearDown() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: 内部

    /// Web ビューの値が変わったら写す。KVO の知らせはメインスレッドで届く。
    private func observe() {
        observations = [
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
        ]
        sync()
    }

    /// 変わった値だけを入れる。同じ値を入れても画面の見張りが動くので、比べてから入れる。
    private func sync() {
        if url != webView.url { url = webView.url }
        let title = webView.title ?? ""
        if self.title != title {
            self.title = title
            if !title.isEmpty { onEvent(.titleChanged(title)) }
        }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if estimatedProgress != webView.estimatedProgress { estimatedProgress = webView.estimatedProgress }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
    }

    /// 読み込みの節目と、新しいタブ・小窓の頼みを受ける。`Page` とは分けて、Web ビューから `Page` へ循環させない。
    private final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var opener: (any TabOpening)?
        let onEvent: @MainActor (Event) -> Void

        init(opener: (any TabOpening)?, onEvent: @escaping @MainActor (Event) -> Void) {
            self.opener = opener
            self.onEvent = onEvent
        }

        /// `target="_blank"` のように新しい窓を求めるリンクと、Command キーを押しながらのクリックを新しいタブに振り替える。
        /// `window.open` はここを通らず、下の `createWebViewWith` に来る。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            preferences: WKWebpagePreferences
        ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            let wantsNewWindow = action.targetFrame == nil
            let commandClick = action.navigationType == .linkActivated && action.modifierFlags.contains(.command)
            guard wantsNewWindow || commandClick, let opener, action.request.url != nil else {
                return (.allow, preferences)
            }
            opener.openTab(with: action.request, inBackground: commandClick)
            return (.cancel, preferences)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onEvent(.started)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onEvent(.committed)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onEvent(.finished)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            onEvent(.failed(Self.message(for: error)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            onEvent(.failed(Self.message(for: error)))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onEvent(.failed("ページを表示するプロセスが終了しました。再読み込みしてください。"))
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            PopupWindows.create(with: configuration, for: action, features: windowFeatures, from: webView, opener: opener)
        }

        /// 表示すべき失敗なら文言を返す。利用者による中断などは `nil`。
        private static func message(for error: any Error) -> String? {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return nil }
            // 102: ダウンロードなどでフレームの読み込みが打ち切られた場合。
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return nil }
            return nsError.localizedDescription
        }
    }
}
