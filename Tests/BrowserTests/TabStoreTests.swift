import Foundation
import Testing
import WebKit
@testable import Browser

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
        store.select(number: 9)
        #expect(store.selectedID == last.id)
    }

    /// ⌃1〜9 と一覧の中のキー操作。番号はフォルダだけを数え、行の選択は端で止まる。
    @Test func folderListByKeyboard() {
        let store = makeStore()
        let url = URL(string: "about:blank")!
        store.bookmarks.add(title: "Loose", url: url)
        let first = store.bookmarks.addFolder(named: "First")
        let second = store.bookmarks.addFolder(named: "Second")
        let a = store.bookmarks.add(title: "A", url: url, folder: second.id)
        let b = store.bookmarks.add(title: "B", url: url, folder: second.id)

        store.toggleFolder(number: 2)
        #expect(store.openFolder == .init(id: second.id, highlighted: 0))
        store.moveFolderHighlight(by: -1)
        #expect(store.openFolder?.highlighted == 0)
        store.moveFolderHighlight(by: 5)
        #expect(store.openFolder?.highlighted == 1)

        // 別のフォルダへ切り替えた後に、古い一覧が閉じた知らせが来ても新しい方は残る。
        store.toggleFolder(number: 1)
        store.closeFolder(second.id)
        #expect(store.openFolder?.id == first.id)
        store.toggleFolder(number: 1)
        #expect(store.openFolder == nil)

        store.toggleFolder(number: 3)
        #expect(store.openFolder == nil)

        store.toggleFolder(second.id)
        let opened = store.activateFolderRow()
        #expect(opened?.bookmarkID == a.id)
        #expect(store.openFolder == nil)

        store.activate(bookmark: b.id)
        store.toggleFolder(second.id)
        #expect(store.openFolder?.highlighted == 1, "見ているページの行から選び始める")
        store.removeBookmark(second.id)
        #expect(store.openFolder == nil)
    }

    /// 閉じたタブの `WebPage` が、読み込み途中でも解放されること。
    @Test func closedTabReleasesItsPage() async throws {
        let store = makeStore()
        weak var page: WebPage?
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
