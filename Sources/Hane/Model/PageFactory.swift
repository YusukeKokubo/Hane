import Foundation
import WebKit

/// ページ（`Page`）の生成と設定を一か所にまとめる。タブ管理（プロファイル）ごとに一つ。
///
/// 設定はここで一つだけ作り、そのプロファイルのすべてのページで使う。ユーザースクリプトなどを足すときは
/// `init` の中で `userContentController` に登録すればよい。設定がページごとにばらつくことはない。
@MainActor
final class PageFactory {
    /// 広告ブロック。テストでは付けない。
    let contentBlocker: ContentBlocker?
    /// ページから始まったダウンロードを引き受ける先。アプリ全体で一つ。
    let downloads: Downloads
    private let configuration: WKWebViewConfiguration

    /// `dataStore` はプロファイルのすべてのページで共有するサイトデータ（Cookieやキャッシュ）の保存先。
    /// 置き場はプロファイルが決める（`ProfileData`）。テストでは終了時に消えるもの。
    /// テストのダウンロードは一時フォルダに置く。
    /// `capturesConsole` は、`hanectl logs` 用に console 出力と例外を拾うか。ページ全部に処理が乗るので、
    /// 開発用の実体だけが付ける。既定はテスト向けに付ける。
    /// `base` は設定の元。省くと全ページで共有する元（`SharedConfiguration`）を写す。
    /// テストで、ほかのテストのページとプロセスプールを分けたいときだけ渡す。
    init(
        dataStore: WKWebsiteDataStore = .nonPersistent(),
        contentBlocker: ContentBlocker? = nil,
        downloads: Downloads = Downloads(directory: Downloads.temporaryDirectory(for: "test-\(UUID().uuidString)")),
        capturesConsole: Bool = true,
        base: WKWebViewConfiguration? = nil
    ) {
        self.contentBlocker = contentBlocker
        self.downloads = downloads
        let configuration = base ?? SharedConfiguration.copy()
        configuration.websiteDataStore = dataStore

        // 受け口は全ページで一つ。ページからの知らせは、どの Web ビューから来たかで振り分ける。
        let userContent = WKUserContentController()
        if capturesConsole { PageLog.attach(to: userContent) }
        KeyNavigation.attach(to: userContent)
        userContent.addUserScript(Self.outerSizeScript)
        contentBlocker?.attach(to: userContent)
        configuration.userContentController = userContent
        configuration.applicationNameForUserAgent = BrowserSettings.userAgentSuffix
        configuration.upgradeKnownHostsToHTTPS = true

        let preferences = WKWebpagePreferences()
        preferences.preferredContentMode = .desktop
        preferences.preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP
        configuration.defaultWebpagePreferences = preferences
        self.configuration = configuration
    }

    /// WKWebView には窓の位置と大きさをページへ渡す公開の口がなく、`outerWidth` と `outerHeight` が 0 になる。
    /// Google スプレッドシートはこれと `innerWidth` の比を拡大率とみなし、表を 4 分の 1 の細かさで描いてぼやけた。
    /// 0 のときだけ、表示している範囲の大きさを答える。
    private static let outerSizeScript = WKUserScript(source: """
        (() => {
          for (const [outer, inner] of [["outerWidth", "innerWidth"], ["outerHeight", "innerHeight"]]) {
            const original = Object.getOwnPropertyDescriptor(window, outer)?.get;
            if (!original) continue;
            Object.defineProperty(window, outer, {
              get() { return original.call(this) || this[inner]; },
              configurable: true, enumerable: true,
            });
          }
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    /// `opener` は、このページから新しいタブや小窓を開くときに頼む先。
    func makePage(opener: (any TabOpening)?, log: PageLog, onEvent: @escaping @MainActor (Page.Event) -> Void) -> Page {
        Page(configuration: configuration, opener: opener, downloads: downloads, log: log, onEvent: onEvent)
    }
}
