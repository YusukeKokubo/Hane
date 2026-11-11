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
    /// 全タブで共有するサイトデータ（Cookieやキャッシュ）の保存先。
    /// 普段使い以外のプロファイルでは、終了時に消える使い捨てにする。
    var dataStore: WKWebsiteDataStore = BrowserProfile.isDefault ? .default() : .nonPersistent()
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

    func makePage(navigationDecider: some WebPage.NavigationDeciding, log: PageLog) -> WebPage {
        SharedProcessPool.install()
        let page = WebPage(configuration: makeConfiguration(log: log), navigationDecider: navigationDecider)
        page.isInspectable = true
        return page
    }
}
