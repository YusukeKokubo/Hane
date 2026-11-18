import Foundation
import Testing
import WebKit
@testable import Hane

@MainActor
@Suite struct BookmarkStoreTests {
    private let a = URL(string: "https://a.example/")!
    private let b = URL(string: "https://b.example/")!
    private let c = URL(string: "https://c.example/")!

    @Test func addsAndFindsByAddress() {
        let store = BookmarkStore()
        let added = store.add(title: "  A  ", url: a)
        #expect(added.title == "A")
        #expect(store.add(title: "", url: b).title == "b.example", "名前が空ならホスト名で代える")
        #expect(store.bookmark(matching: URL(string: "https://a.example")!)?.id == added.id, "末尾の / の違いは同じ行き先")
        #expect(store.bookmark(matching: c) == nil)
    }

    @Test func reordersAndRemoves() {
        let store = BookmarkStore()
        let first = store.add(title: "A", url: a)
        let second = store.add(title: "B", url: b)
        let third = store.add(title: "C", url: c, before: second.id)
        #expect(store.bookmarks.map(\.id) == [first.id, third.id, second.id])

        store.move(first.id, to: nil)
        #expect(store.bookmarks.map(\.id) == [third.id, second.id, first.id], "目印を省くと末尾へ")
        store.move(first.id, to: nil, before: third.id)
        #expect(store.bookmarks.map(\.id) == [first.id, third.id, second.id])

        #expect(store.remove(third.id))
        #expect(!store.remove(UUID()))
        #expect(store.bookmarks.map(\.id) == [first.id, second.id])
    }

    @Test func renamesAndRepoints() {
        let store = BookmarkStore()
        let bookmark = store.add(title: "A", url: a)

        store.rename(bookmark.id, to: "新しい名前")
        store.rename(bookmark.id, to: "   ")
        store.setURL(bookmark.id, to: b)

        #expect(store.bookmark(bookmark.id)?.title == "新しい名前", "空の名前は受け付けない")
        #expect(store.bookmark(bookmark.id)?.url == b)
    }

    @Test func persistsAcrossLaunches() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "bookmarks-\(UUID().uuidString)/bookmarks.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let saved = BookmarkStore(fileURL: file)
        saved.add(title: "A", url: a)
        saved.add(title: "B", url: b, group: PinnedGroup(id: UUID()))
        saved.add(title: "C", url: c, group: PinnedGroup(id: nil))

        let loaded = BookmarkStore(fileURL: file)
        #expect(loaded.bookmarks == saved.bookmarks)
    }

    /// フォルダを持てた版 1 のファイルは、フォルダの中身をフォルダの位置へ並べて読む。
    @Test func readsFoldersOfOldFilesInPlace() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bookmarks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "bookmarks.json")
        func entry(_ title: String, _ url: URL) -> String {
            #"{"id": "\#(UUID().uuidString)", "title": "\#(title)", "url": "\#(url.absoluteString)"}"#
        }
        let old = """
        {"version": 1, "items": [
          {"bookmark": \(entry("A", a))},
          {"folder": {"id": "\(UUID().uuidString)", "name": "仕事", "bookmarks": [\(entry("B", b)), \(entry("C", c))]}}
        ]}
        """
        try Data(old.utf8).write(to: file)

        let store = BookmarkStore(fileURL: file)
        #expect(store.bookmarks.map(\.title) == ["A", "B", "C"])

        store.rename(store.bookmarks[0].id, to: "A2")
        #expect(BookmarkStore(fileURL: file).bookmarks.map(\.title) == ["A2", "B", "C"], "書き戻すと新しい形になる")
    }

    @Test func setsBrokenFileAsideInsteadOfOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bookmarks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "bookmarks.json")
        try Data("not json".utf8).write(to: file)

        let store = BookmarkStore(fileURL: file)
        #expect(store.bookmarks.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("bookmarks.broken-") })
    }
}

/// ブックマークとタブを一列に並べたときの、ページの持ち方。
@MainActor
@Suite struct BookmarkTabTests {
    private let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()))
    private let blank = URL(string: "about:blank")!

    /// ページのアドレスが決まるまで待つ。
    private func waitForURL(_ tab: Tab) async throws {
        for _ in 0..<100 where tab.page?.url == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(tab.page?.url != nil)
    }

    @Test func activatingOpensPageInPlace() {
        let bookmark = store.bookmarks.add(title: "A", url: blank)

        let tab = store.activate(bookmark: bookmark.id)
        #expect(tab != nil)
        #expect(store.tabs.count == 1, "普通のタブは増えない")
        #expect(store.selectedID == tab?.id)
        #expect(store.allTabs.first?.id == tab?.id, "ブックマークのページは普通のタブより前に並ぶ")

        store.selectedID = store.tabs[0].id
        #expect(store.activate(bookmark: bookmark.id)?.id == tab?.id, "二度目は同じページへ切り替えるだけ")
        #expect(store.bookmarkTabs.count == 1)
    }

    @Test func closingBookmarkPageKeepsBookmark() throws {
        let bookmark = store.bookmarks.add(title: "A", url: blank)
        let normal = store.tabs[0]
        let tab = try #require(store.activate(bookmark: bookmark.id))

        #expect(store.close(tab.id))
        #expect(store.bookmarkTabs.isEmpty)
        #expect(store.bookmarks.bookmark(bookmark.id) != nil)
        #expect(store.selectedID == normal.id)
    }

    @Test func closingLastPageLeavesAnEmptyTab() throws {
        let bookmark = store.bookmarks.add(title: "A", url: blank)
        let tab = try #require(store.activate(bookmark: bookmark.id))
        store.close(store.tabs[0].id)
        #expect(store.tabs.isEmpty)

        #expect(store.close(tab.id), "ブックマークのページを閉じてもウインドウは残す")
        #expect(store.tabs.count == 1)
        #expect(store.selectedID == store.tabs[0].id)
    }

    @Test func pinningMovesTabToBookmarks() async throws {
        let tab = store.tabs[0]
        tab.load(URLRequest(url: blank))
        try await waitForURL(tab)

        let bookmark = try #require(store.pin(tab.id, title: "空"))
        #expect(store.tabs.isEmpty)
        #expect(store.bookmarkTabs[bookmark.id]?.id == tab.id, "ページはそのまま引き継ぐ")
        #expect(store.bookmarkID(of: tab) == bookmark.id)
        #expect(store.bookmarks.bookmark(bookmark.id)?.title == "空")
        #expect(store.selectedID == tab.id)
    }

    @Test func removingBookmarkKeepsPageAsTab() throws {
        let bookmark = store.bookmarks.add(title: "A", url: blank)
        let tab = try #require(store.activate(bookmark: bookmark.id))

        store.removeBookmark(bookmark.id)
        #expect(store.bookmarkTabs.isEmpty)
        #expect(store.tabs.last?.id == tab.id)
        #expect(store.bookmarkID(of: tab) == nil)
        #expect(store.selectedID == tab.id)
    }

    @Test func dropReordersAndPins() async throws {
        let first = store.bookmarks.add(title: "A", url: blank)
        let second = store.bookmarks.add(title: "B", url: blank)
        let tab = store.tabs[0]
        tab.load(URLRequest(url: blank))
        try await waitForURL(tab)

        store.drop(.tab(tab.id), pinningTo: nil, before: first.id)
        let pinned = try #require(store.bookmarkID(of: tab))
        #expect(store.bookmarks.bookmarks.map(\.id) == [pinned, first.id, second.id])

        store.drop(.bookmark(pinned), pinningTo: nil, before: nil)
        #expect(store.bookmarks.bookmarks.map(\.id) == [first.id, second.id, pinned])

        store.drop(.bookmark(second.id), pinningTo: nil, before: first.id)
        #expect(store.bookmarks.bookmarks.map(\.id) == [second.id, first.id, pinned])
    }

    @Test func pinsOnlyIntoTheShownGroup() async throws {
        let tab = store.tabs[0]
        tab.load(URLRequest(url: blank))
        try await waitForURL(tab)

        #expect(store.pin(tab.id, to: PinnedGroup(id: UUID())) == nil, "出していない組へ固定すると見えなくなるので断る")
        let pinned = try #require(store.pinToGroup(tab.id))
        #expect(pinned.group == PinnedGroup(id: nil))
        #expect(store.groupBookmarks.map(\.id) == [pinned.id])
        #expect(store.sharedBookmarks.isEmpty)
        #expect(store.bookmarkTabs[pinned.id]?.id == tab.id)
    }

    @Test func tracksPagesThatWanderedAway() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "away-\(UUID().uuidString).html")
        try "<title>Away</title>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let bookmark = store.bookmarks.add(title: "A", url: blank)
        let tab = try #require(store.activate(bookmark: bookmark.id))
        try await waitForURL(tab)
        #expect(store.awayTitle(for: bookmark) == nil)

        tab.load(URLRequest(url: file))
        for _ in 0..<100 where tab.page?.url != file {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.awayTitle(for: bookmark) != nil)

        store.updateBookmarkToCurrentPage(bookmark.id)
        let updated = try #require(store.bookmarks.bookmark(bookmark.id))
        #expect(updated.url == file)
        #expect(store.awayTitle(for: updated) == nil)
    }

    /// 閉じたブックマークのページも解放されること。
    @Test func closedBookmarkPageReleasesItsPage() async throws {
        let bookmark = store.bookmarks.add(title: "A", url: blank)
        weak var page: Page?
        weak var tab: Tab?

        do {
            let opened = try #require(store.activate(bookmark: bookmark.id))
            page = opened.page
            tab = opened
            store.close(opened.id)
        }

        for _ in 0..<50 where page != nil || tab != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab == nil)
        #expect(page == nil)
    }
}
