import Foundation
import Testing
import WebKit
@testable import Hane

@MainActor
@Suite struct TabStoreTests {
    private func makeStore() -> TabStore {
        TabStore(factory: PageFactory(dataStore: .nonPersistent()))
    }

    @Test func startsWithOneSelectedTab() {
        let store = makeStore()
        #expect(store.tabs.count == 1)
        #expect(store.selectedID == store.tabs[0].id)
    }

    @Test func closingSelectsNeighbour() {
        let store = makeStore()
        let first = store.tabs[0]
        let second = store.newTab()
        let third = store.newTab()

        store.selectedID = second.id
        #expect(store.close(second.id))
        #expect(store.selectedID == third.id)

        #expect(store.close(third.id))
        #expect(store.selectedID == first.id)

        #expect(!store.close(first.id))
        #expect(store.tabs.isEmpty)
        #expect(store.selectedID == nil)
    }

    /// 開いたタブをほかへ移らずに閉じると、開く前に選んでいたタブへ戻る。ほかへ移ったあとなら隣へ。
    @Test func closingAnOpenedTabReturnsToWhereItCameFrom() {
        let store = makeStore()
        let first = store.tabs[0]
        let second = store.newTab()
        _ = store.newTab()
        store.selectedID = first.id

        let opened = store.open(URLRequest(url: localURL("opened")))
        #expect(store.tabs.firstIndex { $0.id == opened.id } == 1, "選んでいたタブの隣に開く")
        #expect(store.close(opened.id))
        #expect(store.selectedID == first.id)

        let visited = store.open(URLRequest(url: localURL("visited")))
        store.selectedID = second.id
        store.selectedID = visited.id
        #expect(store.close(visited.id))
        #expect(store.selectedID == second.id, "ほかへ移ったあとは隣へ")
    }

    /// 読み込んでも失敗するだけで、ネットワークには出ないアドレス。
    private func localURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "HaneTabStoreTests-\(name).html")
    }

    /// ⇧⌘T は最後に閉じたページから順に、閉じたときの位置へ開き直して選ぶ。まっさらなタブは数えない。
    @Test func reopensClosedTabsInReverseOrderAtTheirPlace() {
        let store = makeStore()
        let blank = store.tabs[0]
        let a = store.open(URLRequest(url: localURL("a")))
        let b = store.open(URLRequest(url: localURL("b")))
        store.newTab()

        store.close(a.id)
        store.close(b.id)
        store.close(blank.id)
        #expect(store.closedTabs.count == 2)

        let reopenedB = store.reopenClosedTab()
        #expect(reopenedB?.url == localURL("b"))
        #expect(store.selectedID == reopenedB?.id)
        #expect(reopenedB?.hasContent == true, "選んだところで起こす")

        let reopenedA = store.reopenClosedTab()
        #expect(reopenedA?.url == localURL("a"))
        #expect(store.tabs.map(\.url) == [nil, localURL("a"), localURL("b")])
        #expect(store.reopenClosedTab() == nil)
    }

    /// ブックマークのページはブックマークの側へ戻す。ブックマークがもうなければ普通のタブとして開く。
    @Test func reopensBookmarkPageIntoItsBookmark() {
        let store = makeStore()
        let kept = store.bookmarks.add(title: "Kept", url: localURL("kept"))
        let gone = store.bookmarks.add(title: "Gone", url: localURL("gone"))
        let keptTab = store.activate(bookmark: kept.id)!
        let goneTab = store.activate(bookmark: gone.id)!
        store.close(keptTab.id)
        store.close(goneTab.id)
        store.removeBookmark(gone.id)

        let plain = store.reopenClosedTab()
        #expect(store.tabs.contains { $0 === plain })
        #expect(plain?.url == localURL("gone"))

        let pinned = store.reopenClosedTab()
        #expect(store.bookmarkTabs[kept.id] === pinned)
    }

    @Test func closedTabsAreLimited() {
        let store = makeStore()
        for index in 0..<(BrowserSettings.closedTabLimit + 5) {
            let tab = store.open(URLRequest(url: localURL("\(index)")))
            store.close(tab.id)
        }
        #expect(store.closedTabs.count == BrowserSettings.closedTabLimit)
        #expect(store.closedTabs.first?.page.url == localURL("5"), "古いものから捨てる")
    }

    @Test func backgroundTabOpensNextToCurrent() {
        let store = makeStore()
        let first = store.tabs[0]
        store.newTab()
        store.selectedID = first.id

        store.openTab(with: URLRequest(url: URL(string: "about:blank")!), inBackground: true)
        #expect(store.tabs.count == 3)
        #expect(store.selectedID == first.id)
        #expect(store.tabs[1].hasContent)
    }

    @Test func selectionWrapsAround() {
        let store = makeStore()
        let first = store.tabs[0]
        let last = store.newTab()

        store.select(offset: 1)
        #expect(store.selectedID == first.id)
        store.activateBarItem(number: 9)
        #expect(store.selectedID == last.id)
    }

    /// ⌘1〜8 はバーに見えている並びのまま左から数える。ブックマークは開き、フォルダは一覧を開け閉めする。
    @Test func barItemsAreNumberedFromTheLeft() {
        let store = makeStore()
        let url = URL(string: "about:blank")!
        let loose = store.bookmarks.add(title: "Loose", url: url)
        let folder = store.bookmarks.addFolder(named: "Folder")
        store.bookmarks.add(title: "Inside", url: url, folder: folder.id)
        let first = store.tabs[0]
        let second = store.newTab()

        store.activateBarItem(number: 3)
        #expect(store.selectedID == first.id, "ブックマークとフォルダの次が最初のタブ")
        store.activateBarItem(number: 2)
        #expect(store.openFolder?.id == folder.id)
        store.activateBarItem(number: 2)
        #expect(store.openFolder == nil, "もう一度押すと閉じる")
        store.activateBarItem(number: 1)
        #expect(store.selected.flatMap(store.bookmarkID(of:)) == loose.id)
        store.activateBarItem(number: 4)
        #expect(store.selectedID == second.id)
        store.activateBarItem(number: 8)
        #expect(store.selectedID == second.id, "並んでいない番号では動かない")
        store.activateBarItem(number: 1)
        store.activateBarItem(number: 9)
        #expect(store.selectedID == second.id, "9 は最後の普通のタブ")
    }

    /// フォルダの一覧の中のキー操作。行の選択は端で止まる。
    @Test func folderListByKeyboard() {
        let store = makeStore()
        let url = URL(string: "about:blank")!
        store.bookmarks.add(title: "Loose", url: url)
        let first = store.bookmarks.addFolder(named: "First")
        let second = store.bookmarks.addFolder(named: "Second")
        let a = store.bookmarks.add(title: "A", url: url, folder: second.id)
        let b = store.bookmarks.add(title: "B", url: url, folder: second.id)

        store.toggleFolder(second.id)
        #expect(store.openFolder == .init(id: second.id, highlighted: 0))
        store.moveFolderHighlight(by: -1)
        #expect(store.openFolder?.highlighted == 0)
        store.moveFolderHighlight(by: 5)
        #expect(store.openFolder?.highlighted == 1)

        // 別のフォルダへ切り替えた後に、古い一覧が閉じた知らせが来ても新しい方は残る。
        store.toggleFolder(first.id)
        store.closeFolder(second.id)
        #expect(store.openFolder?.id == first.id)
        store.toggleFolder(first.id)
        #expect(store.openFolder == nil)

        store.toggleFolder(second.id)
        let opened = store.activateFolderRow()
        #expect(opened.flatMap(store.bookmarkID(of:)) == a.id)
        #expect(store.openFolder == nil)

        store.activate(bookmark: b.id)
        store.toggleFolder(second.id)
        #expect(store.openFolder?.highlighted == 1, "見ているページの行から選び始める")
        store.removeBookmark(second.id)
        #expect(store.openFolder == nil)
    }

    /// 閉じたタブのページが、読み込み途中でも解放されること。
    @Test func closedTabReleasesItsPage() async throws {
        let store = makeStore()
        weak var page: Page?
        weak var tab: Tab?

        do {
            let opened = store.newTab()
            opened.load(URLRequest(url: URL(string: "about:blank")!))
            page = opened.page
            tab = opened
            store.close(opened.id)
        }

        // 監視タスクの後始末が走るのを待つ。
        for _ in 0..<50 where page != nil || tab != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab == nil)
        #expect(page == nil)
    }
}
