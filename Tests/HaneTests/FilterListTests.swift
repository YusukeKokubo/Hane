import Foundation
import Testing
import WebKit
@testable import Hane

@Suite struct FilterListTests {
    private func rules(_ line: String) -> [ContentRule] {
        switch FilterList.parse(line) {
        case .hide(let rule): [rule]
        case .block(let rules), .exception(let rules): rules
        case .ignored, .skipped: []
        }
    }

    @Test func domainAnchorMatchesHostAndSubdomains() throws {
        let rule = try #require(rules("||ads.example.com^").first)
        #expect(rule.trigger.urlFilter == "^[^:]+://+([^/]+\\.)?ads\\.example\\.com[/:?=&]")
        #expect(rule.action.type == .block)
    }

    /// 種類の指定がなければ、ページ本体は止めず、子フレームだけは止める。
    @Test func untypedFilterSkipsTopLevelPages() {
        let all = rules("/banner/*/img")
        #expect(all.count == 2)
        #expect(all[0].trigger.resourceType?.contains("document") == false)
        #expect(all[1].trigger.resourceType == ["document"])
        #expect(all[1].trigger.loadContext == ["child-frame"])
        #expect(all[0].trigger.urlFilter == "/banner/.*/img")
    }

    @Test func optionsBecomeTriggerConditions() throws {
        let rule = try #require(rules("||tracker.net^$script,third-party,domain=a.com|~b.a.com").first)
        #expect(rules("||tracker.net^$script,third-party,domain=a.com|~b.a.com").count == 1)
        #expect(rule.trigger.resourceType == ["script"])
        #expect(rule.trigger.loadType == ["third-party"])
        #expect(rule.trigger.ifDomain == ["*a.com"])
        #expect(rule.trigger.unlessDomain == nil)

        let negated = try #require(rules("||cdn.net/ad.js$~script,~third-party").first)
        #expect(negated.trigger.resourceType?.contains("script") == false)
        #expect(negated.trigger.loadType == ["first-party"])
    }

    /// 末尾の区切りは、アドレスの終わりでもよい。
    @Test func trailingSeparatorAllowsEndOfURL() throws {
        let rule = try #require(rules("||example.com/ads.js^$script").first)
        #expect(rule.trigger.urlFilter.hasSuffix("ads\\.js([/:?=&].*)?$"))
    }

    @Test func untranslatableFiltersAreSkipped() {
        for line in [
            "/^https?:\\/\\/ads\\./",             // 正規表現
            "||example.com^$popup",                // ポップアップ
            "||example.com^$csp=script-src 'self'", // ページの書き換え
            "example.com#@#.ad",                   // 要素を隠す例外
            "example.com#?#.ad:-abp-has(.x)",      // 拡張セレクタ
            "example.com##+js(nowebrtc)",          // スクリプトレット
            "example.*##.ad",                      // ワイルドカードのドメイン
            "example.com$$script[tag-content=\"ad\"]",
            "||example.com^$domain=example.*",     // 対象のドメインが全部表せない
        ] {
            #expect(FilterList.parse(line) == .skipped, "\(line)")
        }
        #expect(FilterList.parse("! comment") == .ignored)
        #expect(FilterList.parse("[Adblock Plus 2.0]") == .ignored)
    }

    @Test func cosmeticFilters() throws {
        let generic = try #require(rules("##.ad-banner").first)
        #expect(generic.action == ContentRule.Action(type: .hide, selector: ".ad-banner"))
        #expect(generic.trigger.ifDomain == nil)

        let scoped = try #require(rules("example.com,~sub.example.com###sidebar-ad").first)
        #expect(scoped.trigger.ifDomain == ["*example.com"])
        #expect(scoped.action.selector == "#sidebar-ad")

        let unless = try #require(rules("~example.com##.promo").first)
        #expect(unless.trigger.unlessDomain == ["*example.com"])
    }

    @Test func siteExceptionCoversEveryLoadOnThePage() throws {
        let rule = try #require(rules("@@||example.com^$document").first)
        #expect(rule.trigger == ContentRule.Trigger.onSite("example.com"))
        #expect(rule.action.type == .ignorePreviousRules)
    }

    /// 例外は、取り消す相手より後ろに並ぶ。
    @Test func exceptionsComeLast() {
        let conversion = FilterList.convert(["@@||good.com^$script", "||bad.com^$script", "##.ad"])
        #expect(conversion.rules.map(\.action.type) == [.hide, .block, .ignorePreviousRules])
    }

    @Test func overLimitDropsChildFrameCopies() {
        let conversion = FilterList.convert(["/banner/img\n##.ad"], limit: 2)
        #expect(conversion.rules.count == 2)
        #expect(conversion.rules.allSatisfy { $0.trigger.loadContext == nil })
    }

    /// 訳したルールを WebKit が実際に受け付けるか。ひとつでも拒まれるとリスト全体が使えなくなる。
    @MainActor
    @Test func webKitCompilesConvertedRules() async throws {
        let lines = [
            "||ads.example.com^", "/banner/*/img", "||tracker.net^$script,third-party,domain=a.com|~b.a.com",
            "||cdn.net/ad.js$~script,~third-party", "||example.com/ads.js^$script", "|https://x.com/ad|",
            "&ad_type=$xmlhttprequest,websocket,ping,other,font,media,stylesheet,image", "||frame.net^$subdocument",
            "||malware.net^$document", "||mixed.net^$all", "@@||good.com/ad.js$script", "@@||site.org^$document",
            "##.ad-banner", "example.com###sidebar", "~example.com##.promo", "*$image,domain=c.com",
            "||case.net/Ad$match-case",
        ]
        let conversion = FilterList.convert([lines.joined(separator: "\n")])
        #expect(conversion.skipped == 0)
        _ = try await Self.compile(conversion.rules)
    }

    /// 同梱しているリストを全部訳して、WebKit がコンパイルできるか。ルール数の上限（15万件）も見張る。
    @MainActor
    @Test func bundledListsCompile() async throws {
        let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Support/Filters")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
        try #require(!files.isEmpty)
        // 訳すのに数秒かかる。メインスレッドでやると、並んで走るほかのテストがその間まるごと止まる。
        let conversion = try await Task.detached {
            FilterList.convert(try files.map { try String(contentsOf: $0, encoding: .utf8) })
        }.value
        print("rules: \(conversion.rules.count) skipped: \(conversion.skipped)")
        #expect(conversion.rules.count < 150_000)
        _ = try await Self.compile(conversion.rules)
    }

    @MainActor
    static func compile(_ rules: [ContentRule]) async throws -> WKContentRuleList? {
        let directory = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let json = try await Task.detached { try ContentRule.encode(rules) }.value
        return try await store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: json)
    }
}

