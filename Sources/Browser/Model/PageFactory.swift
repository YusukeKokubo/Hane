import Foundation
import WebKit

/// `WebPage` の生成と設定を一か所にまとめる。
///
/// コンテンツブロッカー（`WKContentRuleList`）やユーザースクリプトを足すときは
/// `makeConfiguration()` の中で `userContentController` に登録すればよい。
/// 全タブがこのファクトリを通るので、設定がタブごとにばらつくことはない。
@MainActor
struct PageFactory {
    /// 全タブで共有するサイトデータ（Cookieやキャッシュ）の保存先。
    var dataStore: WKWebsiteDataStore = .default()

    func makeConfiguration() -> WebPage.Configuration {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = BrowserSettings.userAgentSuffix
        configuration.upgradeKnownHostsToHTTPS = true

        var preferences = WebPage.NavigationPreferences()
        preferences.preferredContentMode = .desktop
        preferences.preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP
        configuration.defaultNavigationPreferences = preferences

        return configuration
    }

    func makePage(navigationDecider: some WebPage.NavigationDeciding) -> WebPage {
        let page = WebPage(configuration: makeConfiguration(), navigationDecider: navigationDecider)
        page.isInspectable = true
        return page
    }
}
