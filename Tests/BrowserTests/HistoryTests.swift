import Foundation
import Testing
import WebKit
@testable import Browser

/// 閲覧履歴の記録と、アドレスバーで補う候補の選び方。
@MainActor
@Suite final class HistoryTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "BrowserHistoryTests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    @Test func completesSiteRootsAndTypedPages() {
        let history = HistoryStore()
        history.recordVisit(to: URL(string: "https://github.com/")!, typed: false, at: now)
        history.recordVisit(to: URL(string: "https://example.com/deep/page")!, typed: false, at: now)

        #expect(history.completion(for: "git", now: now)?.text == "github.com", "サイトの入口はリンクで来ただけでも補う")
        #expect(history.completion(for: "exa", now: now) == nil, "リンクで通っただけの深いページは補わない")

        history.recordVisit(to: URL(string: "https://example.com/deep/page")!, typed: true, at: now)
        #expect(history.completion(for: "exa", now: now)?.text == "example.com/deep/page")
    }

    /// `https://` や `www.` から打っても、省いて打っても補う。打った部分の大文字小文字は変えない。
    @Test func matchesWithOrWithoutSchemeAndWWW() {
        let history = HistoryStore()
        let url = URL(string: "https://www.apple.com/")!
        history.recordVisit(to: url, typed: true, at: now)

        #expect(history.completion(for: "App", now: now) == HistoryCompletion(url: url, text: "Apple.com"))
        #expect(history.completion(for: "www.ap", now: now)?.text == "www.apple.com")
        #expect(history.completion(for: "https://w", now: now)?.text == "https://www.apple.com")
        #expect(history.completion(for: "apple.com", now: now) == nil, "補う続きがなければ何もしない")
        #expect(history.completion(for: "pple", now: now) == nil, "途中からは補わない")
        #expect(history.completion(for: "", now: now) == nil)
    }

    @Test func prefersTypedAndRecent() {
        let history = HistoryStore()
        let old = URL(string: "https://news.example/old")!
        let recent = URL(string: "https://news.example/recent")!
        for _ in 0..<3 { history.recordVisit(to: old, typed: true, at: daysAgo(300)) }
        history.recordVisit(to: recent, typed: true, at: daysAgo(1))
        #expect(history.completion(for: "news", now: now)?.url == recent, "長く訪れていないものは軽くなる")

        let root = URL(string: "https://news.example/")!
        for _ in 0..<5 { history.recordVisit(to: root, typed: false, at: daysAgo(1)) }
        #expect(history.completion(for: "news", now: now)?.url == recent, "打って訪れた回数を重く見る")
    }

    @Test func skipsPagesThatMakeNoSenseToComplete() {
        let history = HistoryStore()
        history.recordVisit(to: URL(string: "about:blank")!, typed: true)
        history.recordVisit(to: URL(string: "data:text/html,hi")!, typed: true)
        #expect(history.entries.isEmpty)
    }

    @Test func recognizesSearchResultPages() throws {
        let search = try #require(AddressResolver.resolve("swift concurrency"))
        #expect(AddressResolver.isSearch(search))
        #expect(!AddressResolver.isSearch(URL(string: "https://www.google.com/maps")!))
    }

    @Test func dropsOldestWhenFull() {
        let history = HistoryStore()
        for index in 0...HistoryStore.limit {
            history.recordVisit(to: URL(string: "https://site\(index).example/")!, typed: false, at: now.addingTimeInterval(Double(index)))
        }
        #expect(history.entries.count == HistoryStore.limit * 9 / 10)
        #expect(history.entries[URL(string: "https://site0.example/")!] == nil)
        #expect(history.entries[URL(string: "https://site\(HistoryStore.limit).example/")!] != nil)
    }

    @Test func savesAndLoads() {
        let file = directory.appending(path: "history.json")
        let history = HistoryStore(fileURL: file)
        let url = URL(string: "https://github.com/")!
        history.recordVisit(to: url, typed: true, at: now)
        history.setTitle("GitHub", for: url)
        history.saveNow()

        let loaded = HistoryStore(fileURL: file)
        #expect(loaded.entries[url] == HistoryEntry(url: url, title: "GitHub", visitCount: 1, typedCount: 1, lastVisit: now))
    }

    /// タブでページを開くと、確定した時点で訪問が数えられ、読み終えると題名が入る。
    @Test func tabsRecordVisits() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let typedPage = directory.appending(path: "typed.html")
        let linkedPage = directory.appending(path: "linked.html")
        try "<title>Typed</title>".write(to: typedPage, atomically: true, encoding: .utf8)
        try "<title>Linked</title>".write(to: linkedPage, atomically: true, encoding: .utf8)

        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()))
        let tab = try #require(store.selected)
        tab.open(typedPage.absoluteString)
        try await waitFor { store.history.entries[typedPage]?.title == "Typed" }
        tab.load(URLRequest(url: linkedPage))
        try await waitFor { store.history.entries[linkedPage]?.title == "Linked" }

        #expect(store.history.entries[typedPage]?.typedCount == 1)
        #expect(store.history.entries[linkedPage]?.typedCount == 0, "アドレスバーを通らない移動は打ったものと数えない")
        #expect(store.history.entries[linkedPage]?.visitCount == 1)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
