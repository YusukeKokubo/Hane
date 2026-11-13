import AppKit
import WebKit

/// ログインの小窓のように、大きさを指定して `window.open` された窓。
///
/// 開いたページへ窓を返さないと `window.opener` がつながらず、小窓で済ませたログインの結果を元のページへ返せない
/// （Google などのログインの小窓は、窓が返らないと「開けなかった」として止まる）。返す Web ビューは WebKit が渡した設定で
/// 作らなければならない。タブとは別の窓なので SwiftUI の窓には載せず、AppKit の窓に置く。
/// 中身はタブと同じ `Page` で持ち、ページが尋ねるものやダウンロードをタブと同じに受ける。
/// 窓は閉じるまでのあいだだけあり、常に動く処理は持たない。
@MainActor
final class PopupWindow: NSObject, NSWindowDelegate {
    let page: Page
    private let window: NSWindow
    /// 小窓の中から開いたものを、タブで開いてもらう先。
    private(set) weak var opener: (any TabOpening)?
    private let onClose: (PopupWindow) -> Void

    var webView: WKWebView { page.webView }

    init(
        configuration: WKWebViewConfiguration,
        features: WKWindowFeatures,
        over parent: NSWindow?,
        opener: (any TabOpening)?,
        downloads: Downloads,
        onClose: @escaping (PopupWindow) -> Void
    ) {
        let size = NSSize(width: features.width?.doubleValue ?? 500, height: features.height?.doubleValue ?? 600)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        self.opener = opener
        self.onClose = onClose
        // 案内役は `Page` が持つので、ここからの知らせは弱く受ける（小窓 → ページ → 小窓と循環させない）。
        weak var popup: PopupWindow?
        page = Page(configuration: configuration, opener: opener, downloads: downloads, log: PageLog()) { event in
            popup?.handle(event)
        }
        super.init()
        popup = self

        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.delegate = self
        updateTitle()
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

    private func handle(_ event: Page.Event) {
        switch event {
        // どのサイトの小窓かを見せる。ログインの小窓なので、行き先が分かるようにしておく。
        case .committed, .titleChanged: updateTitle()
        // ログインが済むと小窓は自分で閉じる。
        case .closeRequested: close()
        // タブを移る・閉じるといったキー操作は、タブのためのものなので小窓では受けない。
        case .started, .finished, .failed, .keyCommand: break
        }
    }

    private func updateTitle() {
        window.title = page.title.isEmpty ? "ポップアップ" : page.title
        window.subtitle = page.url?.host() ?? ""
    }

    func close() {
        window.close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        page.tearDown()
        // 閉じた窓は AppKit がしばらく掴んでいることがあり、中に置いたままだと Web ビューごとページが残る
        // （開いた側からは window.closed が false のままに見える）。窓から外して、ここで手放す。
        window.contentView = nil
        onClose(self)
    }
}
