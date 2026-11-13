import Foundation
import Testing
import WebKit
@testable import Hane

/// 閲覧状態の保存と、再起動したときのタブの戻し方。
@MainActor
@Suite final class SessionTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "HaneSessionTests-\(UUID().uuidString)")
    private var file: URL { directory.appending(path: "session.json") }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 読み込んでも失敗するだけで、ネットワークには出ないアドレス。
    private func page(_ name: String, bookmark: UUID? = nil) -> SavedPage {
        SavedPage(url: directory.appending(path: "\(name).html"), title: name, bookmark: bookmark)
    }

    private func makeStore(bookmarks: BookmarkStore = BookmarkStore()) -> TabStore {
        TabStore(factory: PageFactory(dataStore: .nonPersistent()), bookmarks: bookmarks, session: SessionStore(fileURL: file))
    }

    private func write(_ session: SavedSession) {
        SessionStore(fileURL: file).save(session)
    }

    @Test func startsWithEmptyTabWithoutSavedSession() {
        let store = makeStore()
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].url == nil)
    }

    /// 選んでいたページだけを読み込み、ほかは選ばれるまで待たせる。
    @Test func restoresTabsAndLoadsOnlySelected() {
        write(SavedSession(pages: [page("a"), page("b"), page("c")], selected: 1))
        let store = makeStore()

        #expect(store.tabs.map(\.title) == ["a", "b", "c"])
        #expect(store.selectedID == store.tabs[1].id)
        #expect(store.tabs.map(\.hasContent) == [false, true, false])

        store.selectedID = store.tabs[0].id
        #expect(store.tabs[0].hasContent)
        #expect(!store.tabs[0].isAsleep)
        #expect(store.tabs[0].title == "a", "ページ自身の題名が届くまでは前回の題名を出す")
    }

    /// 戻したタブから別のページへ移ったら、前回の題名はもう使わない。
    @Test func restoredTitleIsDroppedAfterNavigatingAway() async throws {
        write(SavedSession(pages: [page("a")], selected: 0))
        let store = makeStore()
        let tab = store.tabs[0]
        tab.load(URLRequest(url: page("elsewhere").url))
        #expect(tab.title != "a")
        #expect(tab.savedPage()?.title != "a", "閲覧状態にも前回の題名を残さない")
    }

    /// 読み込んでいないページも、読み込みに失敗したページも、次の保存で消えない。
    @Test func snapshotKeepsPagesNotYetShown() async throws {
        let saved = SavedSession(pages: [page("a"), page("b")], selected: 0)
        write(saved)
        let store = makeStore()

        // 選んだページは存在しないファイルなので、読み込みは失敗する。
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.sessionSnapshot().pages.map(\.url) == saved.pages.map(\.url))
        #expect(store.sessionSnapshot().selected == 0)
        #expect(store.sessionSnapshot().pages[1].title == "b")
    }

    @Test func restoresBookmarkPages() {
        let bookmarks = BookmarkStore()
        let pinned = bookmarks.add(title: "Pinned", url: URL(string: "https://pinned.example/")!)
        let gone = UUID()
        write(SavedSession(pages: [page("away", bookmark: pinned.id), page("orphan", bookmark: gone), page("tab")], selected: 2))
        let store = makeStore(bookmarks: bookmarks)

        #expect(store.bookmarkTabs[pinned.id]?.title == "away")
        #expect(store.bookmarkTabs[pinned.id]?.hasContent == false)
        #expect(store.awayTitle(for: pinned) == "away", "ブックマークから離れた先にいたことも戻す")
        // ブックマークが見つからないページは普通のタブとして残す。
        #expect(store.tabs.map(\.title) == ["orphan", "tab"])
        #expect(store.bookmarkID(of: store.tabs[0]) == nil)
    }

    /// 戻せるページがなければ、今までどおり空のタブで始める。
    @Test func emptySessionStartsWithNewTab() {
        write(SavedSession(pages: [], selected: nil))
        let store = makeStore()
        #expect(store.tabs.count == 1)
        #expect(store.selectedID == store.tabs[0].id)
    }

    @Test func brokenFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: file)
        let store = makeStore()

        #expect(store.tabs.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("session.broken-") })
    }

    /// タブの増減や選択の変化を拾って、ひとりでに書き出す。
    @Test func writesChangesAsTheyHappen() async throws {
        write(SavedSession(pages: [page("a")], selected: 0))
        let store = makeStore()
        store.open(URLRequest(url: page("b").url))

        var saved: SavedSession?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            saved = SessionStore(fileURL: file).load()
            if saved?.pages.count == 2 { break }
        }
        #expect(saved?.pages.map(\.url) == [page("a").url, page("b").url])
        #expect(saved?.selected == 1)

        store.close(store.tabs[1].id)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            saved = SessionStore(fileURL: file).load()
            if saved?.pages.count == 1 { break }
        }
        #expect(saved?.pages.map(\.url) == [page("a").url])
        #expect(saved?.selected == 0)
    }

    /// 題名が変わっただけでは書き出さない。題名は次の書き出しに乗る。
    @Test func titleChangesAloneDoNotRewrite() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let html = directory.appending(path: "chat.html")
        try "<title>chat</title>".write(to: html, atomically: true, encoding: .utf8)
        let store = makeStore()
        let tab = try #require(store.selected)
        tab.load(URLRequest(url: html))
        for _ in 0..<100 where SessionStore(fileURL: file).load()?.pages.first?.title != "chat" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(SessionStore(fileURL: file).load()?.pages.first?.title == "chat", "読み終えた後に届いた題名も書き出す")
        let written = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? UInt64

        _ = try await tab.page?.callJavaScript("document.title = '(3) chat'", arguments: [:], contentWorld: .page)
        for _ in 0..<50 where tab.title != "(3) chat" {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? UInt64
        #expect(after == written, "題名の変化だけで書き直した")

        store.saveSession()
        #expect(SessionStore(fileURL: file).load()?.pages.first?.title == "(3) chat")
    }
}

/// しばらく使っていないタブを眠らせてページを手放し、選ばれたら履歴ごと起こす。
@MainActor
@Suite final class TabSleepTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "HaneSleepTests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(name).html")
        try "<title>\(name)</title><p>\(name)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 読み込みが済んで、そのアドレスに着くまで待つ。
    private func arrive(_ tab: Tab, at url: URL) async throws {
        for _ in 0..<150 where tab.page?.url != url || tab.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(tab.page?.url == url && !tab.isLoading, "\(String(describing: tab.page?.url))")
    }

    /// 二つ移ってから一つ戻ったタブ。戻る先と進む先が一つずつある。
    private func browsedTab(in store: TabStore) async throws -> (tab: Tab, pages: [URL]) {
        let pages = try ["one", "two", "three"].map(write)
        let tab = store.open(URLRequest(url: pages[0]))
        try await arrive(tab, at: pages[0])
        tab.load(URLRequest(url: pages[1]))
        try await arrive(tab, at: pages[1])
        tab.load(URLRequest(url: pages[2]))
        try await arrive(tab, at: pages[2])
        tab.goBack()
        try await arrive(tab, at: pages[1])
        return (tab, pages)
    }

    @Test func sleepingReleasesThePageAndWakingRestoresHistory() async throws {
        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()))
        let (tab, pages) = try await browsedTab(in: store)
        store.selectedID = store.tabs[0].id

        weak var released: Page?
        do {
            released = tab.page
            #expect(tab.sleep())
        }
        for _ in 0..<50 where released != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(released == nil, "眠らせたページは手放す")
        #expect(tab.isAsleep)
        #expect(tab.url == pages[1])
        #expect(tab.title == "two", "眠っていても題名は出す")

        store.selectedID = tab.id
        try await arrive(tab, at: pages[1])
        #expect(tab.canGoBack && tab.canGoForward)
        tab.goForward()
        try await arrive(tab, at: pages[2])
    }

    /// 再起動しても、戻る・進むの履歴が残る。
    @Test func sessionKeepsHistoryAcrossLaunches() async throws {
        let first = TabStore(factory: PageFactory(dataStore: .nonPersistent()))
        let (_, pages) = try await browsedTab(in: first)
        let saved = first.sessionSnapshot()
        #expect(saved.pages.last?.state != nil)

        let session = SessionStore()
        session.save(saved)
        let next = TabStore(factory: PageFactory(dataStore: .nonPersistent()), session: session)
        let tab = try #require(next.selected)
        #expect(tab.url == pages[1])
        try await arrive(tab, at: pages[1])
        #expect(tab.canGoBack && tab.canGoForward)
        tab.goBack()
        try await arrive(tab, at: pages[0])
    }

    /// 控えを読めなくても、アドレスから開き直す。
    @Test func unreadableStateFallsBackToTheAddress() async throws {
        let url = try write("plain")
        let session = SessionStore()
        session.save(SavedSession(pages: [SavedPage(url: url, title: "plain", state: Data("broken".utf8))], selected: 0))
        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()), session: session)
        try await arrive(try #require(store.selected), at: url)
    }

    /// 画面から外れて時間の経ったタブだけを、選択が変わったときに眠らせる。
    @Test func idleTabsFallAsleepWhenTheSelectionChanges() async throws {
        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()))
        let old = store.open(URLRequest(url: try write("old")))
        let recent = store.open(URLRequest(url: try write("recent")))
        try await arrive(old, at: directory.appending(path: "old.html"))
        try await arrive(recent, at: directory.appending(path: "recent.html"))
        store.selectedID = store.tabs[0].id
        old.lastShown = Date(timeIntervalSinceNow: -BrowserSettings.tabSleepDelay - 1)

        store.sleepIdleTabs()
        for _ in 0..<50 where old.hasContent {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(old.isAsleep)
        #expect(recent.hasContent)
        #expect(store.sessionSnapshot().pages.map(\.title).contains("old"), "眠っているタブも閲覧状態に残る")
    }
}
