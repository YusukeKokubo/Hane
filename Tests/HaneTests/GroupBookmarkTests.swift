import Foundation
import Testing
import WebKit
@testable import Hane

/// 組の固定（組ごとのブックマーク）と、普通のタブの並べ替え。
@MainActor
@Suite struct GroupBookmarkTests {
    private let blank = URL(string: "about:blank")!

    private func makeStore(bookmarks: BookmarkStore = BookmarkStore()) -> TabStore {
        TabStore(factory: PageFactory(dataStore: .nonPersistent()), bookmarks: bookmarks)
    }

    @Test func groupBookmarksShowOnlyInTheirGroup() throws {
        let store = makeStore()
        let group = try #require(store.createGroup(named: "A"))
        let shared = store.bookmarks.add(title: "S", url: blank)
        let pin = store.bookmarks.add(title: "P", url: blank, group: PinnedGroup(id: group.id))
        let ungrouped = store.bookmarks.add(title: "U", url: blank, group: PinnedGroup(id: nil))
        #expect(store.barBookmarks.map(\.id) == [shared.id, pin.id])
        #expect(store.listedBookmarks.map(\.id) == [shared.id, ungrouped.id, pin.id])

        let pinTab = try #require(store.activate(bookmark: pin.id))
        #expect(store.allTabs.first?.id == pinTab.id, "組の固定は普通のタブより前に並ぶ")
        store.selectedID = store.tabs[0].id
        store.activateBarItem(number: 1)
        #expect(store.bookmarkTabs[shared.id] != nil, "番号はどの組でも並ぶものから数える")
        store.activateBarItem(number: 2)
        #expect(store.selectedID == pinTab.id)

        store.showGroup(nil)
        #expect(store.barBookmarks.map(\.id) == [shared.id, ungrouped.id])
        #expect(!store.allTabs.contains { $0 === pinTab })
        #expect(store.everyTab.contains { $0 === pinTab }, "ほかの組の固定のページも閉じずに持つ")

        #expect(store.activate(bookmark: pin.id) === pinTab)
        #expect(store.currentGroupID == group.id, "ほかの組の固定を開くと、その組を出す")
        #expect(store.selectedID == pinTab.id)
    }

    @Test func groupWithOnlyPinsSelectsAPinnedPage() throws {
        let store = makeStore()
        let group = try #require(store.createGroup(named: "A"))
        let pin = store.bookmarks.add(title: "P", url: blank, group: PinnedGroup(id: group.id))
        let blankTab = store.tabs[0]
        let pinTab = try #require(store.activate(bookmark: pin.id))
        store.selectedID = blankTab.id
        store.showGroup(nil)
        // 前に選んでいたタブを組の外へ出して、組には固定だけが残るようにする。
        store.move(blankTab.id, to: nil)

        store.showGroup(group.id)
        #expect(store.selectedID == pinTab.id, "普通のタブがなくても、開いている固定があればそこを選ぶ")
        #expect(store.tabs.isEmpty)
    }

    @Test func removingGroupMovesItsPinsToUngrouped() throws {
        let store = makeStore()
        let group = try #require(store.createGroup(named: "A"))
        let pin = store.bookmarks.add(title: "P", url: blank, group: PinnedGroup(id: group.id))
        store.removeGroup(group.id)
        #expect(store.bookmarks.bookmark(pin.id)?.group == PinnedGroup(id: nil))
        #expect(store.groupBookmarks.map(\.id) == [pin.id])
    }

    @Test func pinsOfVanishedGroupsAreUngroupedOnLaunch() {
        let bookmarks = BookmarkStore()
        let shared = bookmarks.add(title: "S", url: blank)
        let pin = bookmarks.add(title: "P", url: blank, group: PinnedGroup(id: UUID()))
        let store = makeStore(bookmarks: bookmarks)
        #expect(bookmarks.bookmark(pin.id)?.group == PinnedGroup(id: nil), "どの組を出しても見えない固定を残さない")
        #expect(bookmarks.bookmark(shared.id)?.group == nil)
        #expect(store.groupBookmarks.map(\.id) == [pin.id])
    }

    @Test func movingBookmarkBetweenPlaces() throws {
        let store = makeStore()
        let group = try #require(store.createGroup(named: "A"))
        let first = store.bookmarks.add(title: "1", url: blank)
        let second = store.bookmarks.add(title: "2", url: blank)

        store.moveBookmark(second.id, to: PinnedGroup(id: group.id))
        #expect(store.sharedBookmarks.map(\.id) == [first.id])
        #expect(store.groupBookmarks.map(\.id) == [second.id])
        store.moveBookmark(first.id, to: PinnedGroup(id: group.id), before: second.id)
        #expect(store.groupBookmarks.map(\.id) == [first.id, second.id])
        store.moveBookmark(first.id, to: PinnedGroup(id: UUID()))
        #expect(store.groupBookmarks.map(\.id) == [first.id, second.id], "ない組へは移さない")

        // 選んでいる固定のページを、ほかの組の固定へ移すと見えなくなるので、選び直す。
        let tab = try #require(store.activate(bookmark: second.id))
        store.moveBookmark(second.id, to: PinnedGroup(id: nil))
        #expect(store.selectedID != tab.id)
        #expect(store.allTabs.contains { $0.id == store.selectedID })
    }

    @Test func removingHiddenGroupPinKeepsPageInItsGroup() throws {
        let store = makeStore()
        let group = try #require(store.createGroup(named: "A"))
        let pin = store.bookmarks.add(title: "P", url: blank, group: PinnedGroup(id: group.id))
        let tab = try #require(store.activate(bookmark: pin.id))
        store.showGroup(nil)

        store.removeBookmark(pin.id)
        #expect(store.tabs(in: group.id).contains { $0 === tab }, "固定を外したページは、その固定の組の普通のタブになる")
        #expect(!store.tabs.contains { $0 === tab })
    }

    @Test func reopeningClosedGroupPinShowsItsGroup() throws {
        let store = makeStore()
        let group = try #require(store.createGroup(named: "A"))
        let pin = store.bookmarks.add(title: "P", url: blank, group: PinnedGroup(id: group.id))
        let tab = try #require(store.activate(bookmark: pin.id))
        store.close(tab.id)
        store.showGroup(nil)

        let reopened = try #require(store.reopenClosedTab())
        #expect(store.currentGroupID == group.id)
        #expect(store.bookmarkTabs[pin.id] === reopened)
        #expect(store.selectedID == reopened.id)
    }

    @Test func dropOnTabsReordersAndUnpins() throws {
        let store = makeStore()
        let first = store.tabs[0]
        let second = store.newTab()
        let third = store.newTab()

        store.dropOnTabs(.tab(third.id), before: first.id)
        #expect(store.tabs.map(\.id) == [third.id, first.id, second.id])
        store.dropOnTabs(.tab(third.id), before: nil)
        #expect(store.tabs.map(\.id) == [first.id, second.id, third.id], "目印を省くと末尾へ")
        store.dropOnTabs(.tab(first.id), before: first.id)
        #expect(store.tabs.map(\.id) == [first.id, second.id, third.id], "自分の上に落としても動かない")

        let open = store.bookmarks.add(title: "Open", url: blank)
        let page = try #require(store.activate(bookmark: open.id))
        store.dropOnTabs(.bookmark(open.id), before: second.id)
        #expect(store.bookmarks.bookmark(open.id) == nil)
        #expect(store.tabs.map(\.id) == [first.id, page.id, second.id, third.id], "開いていたページは落とした場所の普通のタブになる")

        let closed = store.bookmarks.add(title: "Closed", url: blank)
        let selected = store.selectedID
        store.dropOnTabs(.bookmark(closed.id), before: nil)
        #expect(store.bookmarks.bookmark(closed.id) == nil)
        #expect(store.tabs.count == 5, "開いていないブックマークは、普通のタブとして裏で開く")
        #expect(store.selectedID == selected)
    }
}
