import Foundation
import Testing
import WebKit
@testable import Hane

/// 普通のタブの組。バーには出している組のタブだけが並び、ほかの組のタブは選ばれていないタブと同じに残る。
@MainActor
@Suite final class TabGroupTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "HaneTabGroupTests-\(UUID().uuidString)")
    private var file: URL { directory.appending(path: "session.json") }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(session: SessionStore = SessionStore()) -> TabStore {
        TabStore(factory: PageFactory(dataStore: .nonPersistent()), session: session)
    }

    /// 読み込んでも失敗するだけで、ネットワークには出ないアドレス。
    private func page(_ name: String, group: UUID? = nil) -> SavedPage {
        SavedPage(url: directory.appending(path: "\(name).html"), title: name, group: group)
    }

    @Test func switchingShowsOnlyThatGroupAndRemembersSelection() throws {
        let store = makeStore()
        let first = store.tabs[0]
        let second = store.newTab()
        let third = store.newTab()

        let group = try #require(store.createGroup(named: "1on1", moving: second.id))
        #expect(store.currentGroupID == group.id)
        #expect(store.tabs.map(\.id) == [second.id])
        #expect(store.selectedID == second.id)
        #expect(store.tabs(in: nil).map(\.id) == [first.id, third.id])
        #expect(store.everyTab.count == 3)

        store.selectedID = second.id
        store.showGroup(nil)
        #expect(store.tabs.map(\.id) == [first.id, third.id])
        #expect(store.selectedID == third.id, "組に入っていない側で最後に選んでいたタブへ戻る")

        store.selectedID = first.id
        store.showGroup(group.id)
        #expect(store.selectedID == second.id)
        store.showGroup(nil)
        #expect(store.selectedID == first.id)
    }

    @Test func emptyGroupOpensBlankTab() throws {
        let store = makeStore()
        let first = store.tabs[0]
        let group = try #require(store.createGroup(named: "空"))
        #expect(store.currentGroupID == group.id)
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].id != first.id)
        #expect(store.selectedID == store.tabs[0].id)
        #expect(store.createGroup(named: "  ") == nil, "名前が空なら作らない")
    }

    @Test func closingLastTabOfGroupKeepsWindow() throws {
        let store = makeStore()
        let other = store.tabs[0]
        _ = try #require(store.createGroup(named: "A"))
        let only = store.tabs[0]

        #expect(store.close(only.id), "ほかの組にタブが残っていれば、窓は閉じない")
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].id != only.id)
        #expect(store.tabs(in: nil).map(\.id) == [other.id])
    }

    @Test func movingWithoutFollowingSelectsNeighbour() throws {
        let store = makeStore()
        let first = store.tabs[0]
        let second = store.newTab()
        let group = try #require(store.createGroup(named: "A"))
        store.showGroup(nil)
        store.selectedID = first.id

        store.move(first.id, to: group.id)
        #expect(store.currentGroupID == nil)
        #expect(store.tabs.map(\.id) == [second.id])
        #expect(store.selectedID == second.id)
        #expect(store.tabs(in: group.id).contains { $0.id == first.id })
    }

    @Test func removingGroupKeepsItsTabs() throws {
        let store = makeStore()
        let first = store.tabs[0]
        let second = store.newTab()
        let group = try #require(store.createGroup(named: "A", moving: second.id))

        store.removeGroup(group.id)
        #expect(store.groups.isEmpty)
        #expect(store.currentGroupID == nil)
        #expect(store.tabs.map(\.id) == [first.id, second.id])
        #expect(store.selectedID == second.id)
    }

    @Test func reopeningReturnsToTheGroupItWasClosedIn() throws {
        let store = makeStore()
        let group = try #require(store.createGroup(named: "A"))
        store.open(URLRequest(url: directory.appending(path: "a.html")))
        let closing = store.open(URLRequest(url: directory.appending(path: "b.html")))
        #expect(store.close(closing.id))
        store.showGroup(nil)

        let reopened = try #require(store.reopenClosedTab())
        #expect(store.currentGroupID == group.id)
        #expect(store.tabs.last?.id == reopened.id)
        #expect(store.selectedID == reopened.id)
    }

    @Test func hiddenGroupPageCanCloseItself() throws {
        let store = makeStore()
        let hidden = store.tabs[0]
        _ = try #require(store.createGroup(named: "A"))
        store.closeTab(hidden)
        #expect(!store.everyTab.contains { $0 === hidden })
        #expect(store.parkedTabs.isEmpty, "空になった組は持たない")
    }

    @Test func groupsSurviveRestart() throws {
        let work = TabGroup(id: UUID(), name: "仕事", showsInBar: true)
        let hobby = TabGroup(id: UUID(), name: "趣味", showsInBar: false)
        SessionStore(fileURL: file).save(SavedSession(
            pages: [page("loose"), page("w1", group: work.id), page("w2", group: work.id), page("h1", group: hobby.id),
                    page("lost", group: UUID())],
            selected: 2, groups: [work, hobby], currentGroup: work.id
        ))
        let store = makeStore(session: SessionStore(fileURL: file))

        #expect(store.groups == [work, hobby])
        #expect(store.currentGroupID == work.id)
        #expect(store.tabs.map(\.title) == ["w1", "w2"])
        #expect(store.selectedID == store.tabs[1].id)
        #expect(store.tabs(in: nil).map(\.title) == ["loose", "lost"], "組が見つからないページは組に入っていないタブにする")
        #expect(store.tabs(in: hobby.id).map(\.title) == ["h1"])

        let snapshot = store.sessionSnapshot()
        #expect(snapshot.groups == [work, hobby])
        #expect(snapshot.currentGroup == work.id)
        #expect(snapshot.pages.map(\.title) == ["loose", "lost", "w1", "w2", "h1"])
        #expect(snapshot.pages.map(\.group) == [nil, nil, work.id, work.id, hobby.id])
        #expect(snapshot.selected == 3)
    }

    @Test func sessionWithoutGroupsStillLoads() throws {
        // 組を持つ前の版のファイル。
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "a.html").absoluteString
        try Data(#"{"version":1,"pages":[{"url":"\#(url)","title":"a"}],"selected":0}"#.utf8).write(to: file)
        let store = makeStore(session: SessionStore(fileURL: file))
        #expect(store.groups.isEmpty)
        #expect(store.tabs.map(\.title) == ["a"])
        #expect(store.sessionSnapshot().groups == nil)
    }
}
