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

    /// `requests` は、フレームごとの記録と、フィルタで止められた要素（記録がなく、要素の状態が失敗を示すもの）を出す。
    /// file: の資源は WebKit が記録しないので、ここで記録として確かめられるのは各フレームのページ本体だけ。
    @Test(.enabled(if: PageScripting.canEnterFrames, "iframe の中へ下りるのは macOS 27 から")) func requestsShowWhatTheFiltersStopped() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filters = directory.appending(path: "filters.txt")
        try "/300x250b.\n".write(to: filters, atomically: true, encoding: .utf8)
        let rules = try #require(WKContentRuleListStore(url: directory.appending(path: "rules")))
        let blocker = ContentBlocker(store: rules, filterFiles: [filters], hidden: HiddenElementStore())
        await blocker.prepare()
        #expect(blocker.filterState == .ready(rules: 2, skipped: 0))

        // 1画素の PNG。
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        for name in ["ok.png", "300x250b.png"] { try png.write(to: directory.appending(path: name)) }
        try "body { color: red }".write(to: directory.appending(path: "300x250b.css"), atomically: true, encoding: .utf8)
        try "<p>ad</p>".write(to: directory.appending(path: "300x250b.html"), atomically: true, encoding: .utf8)
        try "<title>Child</title><p>child</p>".write(to: directory.appending(path: "child.html"), atomically: true, encoding: .utf8)
        let page = directory.appending(path: "page.html")
        try """
        <title>Page</title><link rel="stylesheet" href="300x250b.css">
        <img src="ok.png"><img src="300x250b.png">
        <iframe src="300x250b.html" width="100" height="50"></iframe>
        <iframe title="Child" src="child.html" width="100" height="50"></iframe>
        <iframe id="hidden" src="child.html?hidden" style="display: none"></iframe>
        """.write(to: page, atomically: true, encoding: .utf8)

        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent(), contentBlocker: blocker))
        let service = ControlService(store: store)
        func run(_ args: String...) async -> ControlResponse { await service.respond(to: ControlRequest(args: args)) }
        #expect(await run("open", page.absoluteString).ok)

        let response = await run("requests")
        #expect(response.ok)
        let output = response.output
        let child = directory.appending(path: "child.html").absoluteString
        #expect(output.contains("main — \(page.absoluteString)\n"), "\(output)")
        #expect(output.contains("navigation    \(page.absoluteString)"), "\(output)")
        // 止められたフレームは about:blank のまま、見えているので snapshot と同じ番号で出る。
        #expect(output.contains("frame 1 (iframe) — about:blank\n  （記録なし）"), "\(output)")
        #expect(output.contains("frame 2 (iframe \"Child\") — \(child)\n"), "\(output)")
        #expect(output.contains("navigation    \(child)\n"), "\(output)")
        // 見えていないフレームも辿る。
        #expect(output.contains("frame h1 (iframe#hidden) — \(child)?hidden"), "\(output)")
        #expect(output.contains("main  img    \(directory.appending(path: "300x250b.png").absoluteString) — 画像が出ていない"), "\(output)")
        #expect(output.contains("main  link   \(directory.appending(path: "300x250b.css").absoluteString)"), "\(output)")
        #expect(output.contains("main  iframe \(directory.appending(path: "300x250b.html").absoluteString) — 中身が空のまま"), "\(output)")
        #expect(!output.contains("ok.png"), "\(output)")

        let images = await run("requests", "--type", "img")
        #expect(images.output.contains("300x250b.png") && !images.output.contains("300x250b.css"), "\(images.output)")
        #expect(!images.output.contains("navigation"), "\(images.output)")

        let json = await run("requests", "--json", "--url", "child")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
        let frames = try #require(object["frames"] as? [[String: Any]])
        #expect(frames.map { $0["frame"] as? String } == ["main", "frame 1", "frame 2", "frame h1"])
        let requests = frames.flatMap { $0["requests"] as? [[String: Any]] ?? [] }
        #expect(requests.map { $0["url"] as? String } == [child, child + "?hidden"], "\(json.output)")
        #expect(frames.allSatisfy { ($0["notLoaded"] as? [Any])?.isEmpty ?? false })
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
