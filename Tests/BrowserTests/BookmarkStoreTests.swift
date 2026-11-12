import Foundation
import Testing
import WebKit
@testable import Browser

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

    @Test func movesIntoFolderAndReorders() {
        let store = BookmarkStore()
        let first = store.add(title: "A", url: a)
        let second = store.add(title: "B", url: b)
        let folder = store.addFolder(named: "仕事")

        store.move(first.id, into: folder.id)
        #expect(store.folderID(containing: first.id) == folder.id)
        #expect(store.items.map(\.id) == [second.id, folder.id])

        // フォルダの中の項目を目印にすると、一段目ではそのフォルダの前に入る。
        let third = store.add(title: "C", url: c, before: first.id)
        #expect(store.items.map(\.id) == [second.id, third.id, folder.id])

        store.move(third.id, into: folder.id, before: first.id)
        #expect(store.folder(folder.id)?.bookmarks.map(\.id) == [third.id, first.id])
        #expect(store.allBookmarks.map(\.id) == [second.id, third.id, first.id])
    }

    @Test func foldersStayOneLevelDeep() {
        let store = BookmarkStore()
        let outer = store.addFolder(named: "外")
        let inner = store.addFolder(named: "中")

        store.move(inner.id, into: outer.id, before: outer.id)
        #expect(store.folders.map(\.id) == [inner.id, outer.id])
        #expect(store.folder(outer.id)?.bookmarks.isEmpty == true)
    }

    @Test func removingFolderRemovesItsBookmarks() {
        let store = BookmarkStore()
        let folder = store.addFolder(named: "仕事")
        let inside = store.add(title: "A", url: a, folder: folder.id)
        let outside = store.add(title: "B", url: b)

        #expect(store.remove(folder.id) == [inside.id])
        #expect(store.items.map(\.id) == [outside.id])
        #expect(store.remove(UUID()).isEmpty)
    }

    @Test func renamesAndRepoints() {
        let store = BookmarkStore()
        let folder = store.addFolder(named: "仕事")
        let bookmark = store.add(title: "A", url: a, folder: folder.id)

        store.rename(bookmark.id, to: "新しい名前")
        store.rename(folder.id, to: "趣味")
        store.rename(folder.id, to: "   ")
        store.setURL(bookmark.id, to: b)

        #expect(store.bookmark(bookmark.id)?.title == "新しい名前")
        #expect(store.bookmark(bookmark.id)?.url == b)
        #expect(store.folder(folder.id)?.name == "趣味", "空の名前は受け付けない")
    }

    @Test func persistsAcrossLaunches() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "bookmarks-\(UUID().uuidString)/bookmarks.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let saved = BookmarkStore(fileURL: file)
        let folder = saved.addFolder(named: "仕事")
        saved.add(title: "A", url: a, folder: folder.id)
        saved.add(title: "B", url: b)

        let loaded = BookmarkStore(fileURL: file)
        #expect(loaded.items == saved.items)
    }

    @Test func setsBrokenFileAsideInsteadOfOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bookmarks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "bookmarks.json")
        try Data("not json".utf8).write(to: file)

        let store = BookmarkStore(fileURL: file)
        #expect(store.items.isEmpty)
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

        let folder = store.bookmarks.addFolder(named: "仕事")
        let bookmark = try #require(store.pin(tab.id, title: "空", folder: folder.id))
        #expect(store.tabs.isEmpty)
        #expect(store.bookmarkTabs[bookmark.id]?.id == tab.id, "ページはそのまま引き継ぐ")
        #expect(store.bookmarkID(of: tab) == bookmark.id)
        #expect(store.bookmarks.folderID(containing: bookmark.id) == folder.id)
        #expect(store.selectedID == tab.id)
    }

    @Test func removingBookmarkKeepsPageAsTab() throws {
        let folder = store.bookmarks.addFolder(named: "仕事")
        let bookmark = store.bookmarks.add(title: "A", url: blank, folder: folder.id)
        let tab = try #require(store.activate(bookmark: bookmark.id))

        store.removeBookmark(folder.id)
        #expect(store.bookmarkTabs.isEmpty)
        #expect(store.tabs.last?.id == tab.id)
        #expect(store.bookmarkID(of: tab) == nil)
        #expect(store.selectedID == tab.id)
    }

    @Test func dropReordersAndPins() async throws {
        let first = store.bookmarks.add(title: "A", url: blank)
        let folder = store.bookmarks.addFolder(named: "仕事")
        let tab = store.tabs[0]
        tab.load(URLRequest(url: blank))
        try await waitForURL(tab)

        store.drop(.tab(tab.id), into: nil, before: first.id)
        let pinned = try #require(store.bookmarkID(of: tab))
        #expect(store.bookmarks.items.map(\.id) == [pinned, first.id, folder.id])

        store.drop(.bookmark(first.id), into: folder.id, before: nil)
        #expect(store.bookmarks.folderID(containing: first.id) == folder.id)

        store.drop(.bookmark(folder.id), into: nil, before: pinned)
        #expect(store.bookmarks.items.map(\.id) == [folder.id, pinned])
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
