import Foundation
import Testing
import WebKit
@testable import Hane

/// 閲覧履歴の記録と、アドレスバーで補う候補の選び方。
@MainActor
@Suite final class HistoryTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "HaneHistoryTests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    @Test func completesSiteRootsAndTypedPages() {
        let history = HistoryStore()
        history.recordVisit(to: URL(string: "https://github.com/")!, from: .other, at: now)
        history.recordVisit(to: URL(string: "https://example.com/deep/page")!, from: .other, at: now)

        #expect(history.completion(for: "git", now: now)?.text == "github.com", "サイトの入口はリンクで来ただけでも補う")
        #expect(history.completion(for: "exa", now: now) == nil, "リンクで通っただけの深いページは補わない")

        history.recordVisit(to: URL(string: "https://example.com/deep/page")!, from: .typed, at: now)
        #expect(history.completion(for: "exa", now: now)?.text == "example.com/deep/page")
    }

    /// `https://` や `www.` から打っても、省いて打っても補う。打った部分の大文字小文字は変えない。
    @Test func matchesWithOrWithoutSchemeAndWWW() {
        let history = HistoryStore()
        let url = URL(string: "https://www.apple.com/")!
        history.recordVisit(to: url, from: .typed, at: now)

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
        for _ in 0..<3 { history.recordVisit(to: old, from: .typed, at: daysAgo(300)) }
        history.recordVisit(to: recent, from: .typed, at: daysAgo(1))
        #expect(history.completion(for: "news", now: now)?.url == recent, "長く訪れていないものは軽くなる")

        let root = URL(string: "https://news.example/")!
        for _ in 0..<5 { history.recordVisit(to: root, from: .other, at: daysAgo(1)) }
        #expect(history.completion(for: "news", now: now)?.url == recent, "打って訪れた回数を重く見る")
    }

    @Test func skipsPagesThatMakeNoSenseToComplete() {
        let history = HistoryStore()
        history.recordVisit(to: URL(string: "about:blank")!, from: .typed)
        history.recordVisit(to: URL(string: "data:text/html,hi")!, from: .typed)
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
            history.recordVisit(to: URL(string: "https://site\(index).example/")!, from: .other, at: now.addingTimeInterval(Double(index)))
        }
        #expect(history.entries.count == HistoryStore.limit * 9 / 10)
        #expect(history.entries[URL(string: "https://site0.example/")!] == nil)
        #expect(history.entries[URL(string: "https://site\(HistoryStore.limit).example/")!] != nil)
    }

    @Test func savesAndLoads() {
        let file = directory.appending(path: "history.json")
        let history = HistoryStore(fileURL: file)
        let url = URL(string: "https://github.com/")!
        history.recordVisit(to: url, from: .typed, at: now)
        history.setTitle("GitHub", for: url)
        history.saveNow()

        let loaded = HistoryStore(fileURL: file)
        var expected = HistoryEntry(url: url, title: "GitHub", visitCount: 1, typedCount: 1, lastVisit: now)
        expected.visitTimes = [now]
        #expect(loaded.entries[url] == expected)
    }

    @Test func countsVisitsBySource() {
        let history = HistoryStore()
        let url = URL(string: "https://example.com/")!
        for source in [VisitSource.typed, .bookmark, .bookmark, .external, .link, .other] {
            history.recordVisit(to: url, from: source, at: now)
        }
        let entry = history.entries[url]
        #expect(entry?.visitCount == 6)
        #expect(entry?.typedCount == 1)
        #expect(entry?.bookmarkCount == 2)
        #expect(entry?.externalCount == 1)
        #expect(entry?.linkCount == 1)
    }

    @Test func keepsRecentVisitTimesSpacedApart() {
        let history = HistoryStore()
        let url = URL(string: "https://news.example/")!
        history.recordVisit(to: url, from: .typed, at: now)
        history.recordVisit(to: url, from: .other, at: now.addingTimeInterval(60))
        #expect(history.entries[url]?.visitTimes == [now], "続けて訪れ直したものは一度と数える")
        #expect(history.entries[url]?.lastVisit == now.addingTimeInterval(60))

        let days = (1...HistoryStore.visitTimesKept + 5).map { now.addingTimeInterval(Double($0) * 86_400) }
        for day in days { history.recordVisit(to: url, from: .typed, at: day) }
        #expect(history.entries[url]?.visitTimes == Array(days.suffix(HistoryStore.visitTimesKept)), "新しいものから決まった数だけ残す")
    }

    @Test func addsViewingTimeToThePageLeft() {
        let history = HistoryStore()
        let first = URL(string: "https://a.example/")!
        let second = URL(string: "https://b.example/")!
        history.recordVisit(to: first, from: .typed, at: now)
        history.recordVisit(to: second, from: .typed, at: now)

        history.view(first, at: now)
        history.view(first, at: now.addingTimeInterval(5))
        history.view(second, at: now.addingTimeInterval(30))
        #expect(history.entries[first]?.viewedSeconds == 30, "同じページのままなら数え直さない")
        history.view(nil, at: now.addingTimeInterval(40))
        #expect(history.entries[second]?.viewedSeconds == 10)

        history.view(second, at: now.addingTimeInterval(100))
        history.view(nil, at: now.addingTimeInterval(100 + 5 * 3600))
        #expect(history.entries[second]?.viewedSeconds == 10 + HistoryStore.longestViewing, "席を離れていた分まで数えない")
    }

    @Test func savingCountsTheViewingSoFar() {
        let history = HistoryStore(fileURL: directory.appending(path: "history.json"))
        let url = URL(string: "https://a.example/")!
        history.recordVisit(to: url, from: .typed, at: now)
        history.view(url, at: now)
        history.saveNow(at: now.addingTimeInterval(20))
        history.view(nil, at: now.addingTimeInterval(30))
        #expect(history.entries[url]?.viewedSeconds == 30, "書き出しで区切っても、続きは数え続ける")
    }

    @Test func loadsVersion1Files() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "history.json")
        let old = #"{"version":1,"entries":[{"url":"https:\/\/github.com\/","title":"GitHub","visitCount":3,"typedCount":2,"lastVisit":0}]}"#
        try old.write(to: file, atomically: true, encoding: .utf8)
        let entry = try #require(HistoryStore(fileURL: file).entries[URL(string: "https://github.com/")!])
        #expect(entry.visitCount == 3 && entry.typedCount == 2 && entry.title == "GitHub")
        #expect(entry.visitTimes.isEmpty && entry.viewedSeconds == 0 && entry.linkCount == 0)
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

        // ページの中のリンクをたどった訪問は、リンクから来たと数える。
        let linking = directory.appending(path: "linking.html")
        try "<title>Linking</title><a href=\"linked.html\">next</a>".write(to: linking, atomically: true, encoding: .utf8)
        tab.load(URLRequest(url: linking), from: .bookmark)
        try await waitFor { store.history.entries[linking]?.title == "Linking" }
        #expect(store.history.entries[linking]?.bookmarkCount == 1)
        _ = try await tab.page?.webView.evaluateJavaScript("document.querySelector('a').click()")
        try await waitFor { store.history.entries[linkedPage]?.visitCount == 2 }
        #expect(store.history.entries[linkedPage]?.linkCount == 1)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
