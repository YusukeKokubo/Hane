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
