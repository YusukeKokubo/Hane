import ControlWire
import Foundation
import WebKit

/// `WebPage` の生成と設定を一か所にまとめる。
///
/// ユーザースクリプトなどを足すときは `makeConfiguration(log:)` の中で
/// `userContentController` に登録すればよい。全タブがこのファクトリを通るので、
/// 設定がタブごとにばらつくことはない。
@MainActor
struct PageFactory {
    /// プロファイルのすべてのタブで共有するサイトデータ（Cookieやキャッシュ）の保存先。
    /// 置き場はプロファイルが決める（`ProfileData`）。テストでは終了時に消えるもの。
    var dataStore: WKWebsiteDataStore = .nonPersistent()
    /// 広告ブロック。テストでは付けない。
    var contentBlocker: ContentBlocker?

    func makeConfiguration(log: PageLog) -> WebPage.Configuration {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore

        // ページごとに別の受け口を持たせ、コンソール出力をそのタブの記録に流す。
        let userContent = WKUserContentController()
        userContent.addUserScript(PageLog.userScript)
        userContent.add(log, name: PageLog.handlerName)
        contentBlocker?.attach(to: userContent)
        configuration.userContentController = userContent
        configuration.applicationNameForUserAgent = BrowserSettings.userAgentSuffix
        configuration.upgradeKnownHostsToHTTPS = true

        var preferences = WebPage.NavigationPreferences()
        preferences.preferredContentMode = .desktop
        preferences.preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP
        configuration.defaultNavigationPreferences = preferences

        return configuration
    }

    /// `opener` は、このページから新しいタブや小窓を開くときに頼む先。
    /// ページの受け口も返す。`WebPage` は作った後に設定を見せないので、読み込むときに使う側が持っておく。
    func makePage(opener: any TabOpening, log: PageLog) -> (page: WebPage, content: WKUserContentController) {
        SharedConfiguration.install()
        PopupWindows.install()
        let configuration = makeConfiguration(log: log)
        let page = WebPage(configuration: configuration, navigationDecider: NavigationDecider(opener: opener))
        page.isInspectable = true
        // ページごとに別の受け口を作っているので、それを鍵に、window.open がどのタブ管理から来たかを引く。
        PopupWindows.register(configuration.userContentController, opener: opener)
        return (page, configuration.userContentController)
    }
}
