import ControlWire
import Foundation
import Testing
import WebKit
@testable import Hane

@MainActor
@Suite struct ContentBlockerTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "blocker-\(UUID().uuidString)")

    /// 同梱のリストを持たない広告ブロック。隠した要素だけを扱う。
    private func makeBlocker(hidden: HiddenElementStore = HiddenElementStore()) throws -> ContentBlocker {
        let store = try #require(WKContentRuleListStore(url: directory.appending(path: "rules")))
        return ContentBlocker(store: store, filterFiles: [], hidden: hidden)
    }

    @Test func siteOfAPage() {
        #expect(HiddenElementStore.site(for: URL(string: "https://www.Example.com/a?b#c")!) == "example.com")
        #expect(HiddenElementStore.site(for: URL(string: "http://news.example.com/")!) == "news.example.com")
        #expect(HiddenElementStore.site(for: URL(string: "file:///tmp/a.html?x=1#top")!) == "file:///tmp/a.html")
        #expect(HiddenElementStore.site(for: URL(string: "about:blank")!) == nil)
    }

    @Test func hiddenElementsBecomeOneRulePerSite() {
        let hidden = HiddenElementStore()
        hidden.add("#ad", on: "example.com")
        hidden.add(".banner", on: "example.com")
        hidden.add("#ad", on: "example.com")
        hidden.add("div.promo", on: "file:///tmp/a.html")
        #expect(hidden.rules == [
            .hide("#ad, .banner", on: .onSite("example.com")),
            .hide("div.promo", on: ContentRule.Trigger(urlFilter: "^file:///tmp/a\\.html")),
        ])
        #expect(hidden.removeAll(on: "example.com") == 2)
        #expect(hidden.selectors(on: "example.com").isEmpty)
    }

    @Test func hiddenElementsAreSaved() {
        let file = directory.appending(path: "hidden-elements.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        HiddenElementStore(fileURL: file).add("#ad", on: "example.com")
        #expect(HiddenElementStore(fileURL: file).selectors(on: "example.com") == ["#ad"])
    }

    /// 隠した要素は、次に読み込んだときルールで隠れる。開いている他のページにも効く。
    @Test func hiddenElementStaysHiddenAfterReload() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = try makeBlocker()
        await blocker.prepare()
        #expect(blocker.filterState == .unavailable)
        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent(), contentBlocker: blocker))
        let service = ControlService(store: store)
        func run(_ args: String...) async -> ControlResponse { await service.respond(to: ControlRequest(args: args)) }

        let file = directory.appending(path: "page.html")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"<title>Page</title><p id="keep">本文</p><div class="ad">広告</div>"#.write(to: file, atomically: true, encoding: .utf8)
        #expect(await run("open", file.absoluteString).ok)

        let hide = await run("hide", ".ad")
        #expect(hide.output.contains("hid 1 element"), "\(hide.output)")
        #expect(await run("hide", ".missing").ok == false)

        #expect(await run("reload").ok)
        #expect(await run("eval", "getComputedStyle(document.querySelector('.ad')).display").output == #""none""#)
        #expect(await run("eval", "getComputedStyle(document.getElementById('keep')).display").output == #""block""#)
        #expect(await run("adblock").output.contains("  .ad"))

        let unhide = await run("unhide")
        #expect(unhide.output.contains("restored 1"), "\(unhide.output)")
        #expect(await run("eval", "getComputedStyle(document.querySelector('.ad')).display").output == #""block""#)
    }

    /// ページの設定が広告ブロックを掴んでも、閉じたタブのページは解放される。
    @Test func closedTabReleasesItsPageWithBlocker() async throws {
        let blocker = try makeBlocker()
        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent(), contentBlocker: blocker))
        weak var page: Page?
        do {
            let opened = store.newTab()
            opened.load(URLRequest(url: URL(string: "about:blank")!))
            page = opened.page
            store.close(opened.id)
        }
        for _ in 0..<50 where page != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(page == nil)
    }
}
