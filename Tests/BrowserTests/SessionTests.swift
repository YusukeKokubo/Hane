import Foundation
import Testing
import WebKit
@testable import Browser

/// 閲覧状態の保存と、再起動したときのタブの戻し方。
@MainActor
@Suite final class SessionTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "BrowserSessionTests-\(UUID().uuidString)")
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
        #expect(!store.tabs[0].isWaitingToLoad)
        #expect(store.tabs[0].title == "a", "ページ自身の題名が届くまでは前回の題名を出す")
    }

    /// 戻したタブから別のページへ移ったら、前回の題名はもう使わない。
    @Test func restoredTitleIsDroppedAfterNavigatingAway() async throws {
        write(SavedSession(pages: [page("a")], selected: 0))
        let store = makeStore()
        let tab = store.tabs[0]
        tab.load(URLRequest(url: page("elsewhere").url))
        #expect(tab.restored == nil)
        #expect(tab.title != "a")
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
        #expect(store.tabs[0].bookmarkID == nil)
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
}
