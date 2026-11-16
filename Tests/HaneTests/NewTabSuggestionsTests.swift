import Foundation
import Testing
@testable import Hane

/// 新しいタブに並べるものの選び方。時差で揺れないよう、協定世界時で数える。
@Suite struct NewTabSuggestionsTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 月曜日（1970年1月5日から7日の倍数の日）の 9:00。
    private let monday = 20_409
    private var now: Date { at(day: monday, hour: 9, minute: 0) }

    private func at(day: Int, hour: Int, minute: Int) -> Date {
        Date(timeIntervalSince1970: Double(day * 86_400 + hour * 3600 + minute * 60))
    }

    private func entry(_ url: String, title: String = "", times: [Date] = [], viewed: Double = 0,
                       links: Int = 0, visits: Int? = nil, typed: Int = 0) -> HistoryEntry {
        var entry = HistoryEntry(url: URL(string: url)!, title: title, visitCount: visits ?? max(times.count, 1),
                                 typedCount: typed, lastVisit: times.last ?? now)
        entry.visitTimes = times
        entry.viewedSeconds = viewed
        entry.linkCount = links
        return entry
    }

    @Test func findsPagesOpenedAroundThisTimeOnWeekdays() {
        // 先週の平日（金〜月）の朝、9:08〜9:12 に開いた。
        let morning = [3, 4, 5, 6, 7].map { at(day: monday - $0, hour: 9, minute: 5 + $0) }
        let evening = [3, 4, 5, 6].map { at(day: monday - $0, hour: 21, minute: 0) }
        let weekend = [2, 9, 16].map { at(day: monday - $0, hour: 9, minute: 0) } // 土曜
        let suggestions = NewTabSuggestions.make(from: [
            entry("https://news.example/", title: "News", times: morning),
            entry("https://tv.example/", times: evening),
            entry("https://weekend.example/", times: weekend),
        ], now: now, timeZone: utc)

        #expect(suggestions.habits.map(\.entry.url.host) == ["news.example"])
        let habit = suggestions.habits.first
        #expect(habit?.dayKind == .weekday)
        #expect(habit?.days == 5)
        #expect(habit?.minute == 9 * 60 + 10, "時刻は真ん中の値")
    }

    @Test func needsSeveralDaysWithinTheLookback() {
        let twice = [3, 4].map { at(day: monday - $0, hour: 9, minute: 0) }
        let old = [30, 31, 32].map { at(day: monday - $0, hour: 9, minute: 0) }
        let suggestions = NewTabSuggestions.make(from: [
            entry("https://twice.example/", times: twice),
            entry("https://old.example/", times: old),
        ], now: now, timeZone: utc)
        #expect(suggestions.habits.isEmpty)
    }

    @Test func countsASiteTogetherAndShowsItsMostOpenedPage() {
        // チャットのように開くたびにアドレスが変わっても、サイトとしては毎朝開いている。
        let suggestions = NewTabSuggestions.make(from: [
            entry("https://chat.example/room/a", title: "A", times: [at(day: monday - 3, hour: 9, minute: 0), at(day: monday - 4, hour: 9, minute: 0)]),
            entry("https://chat.example/room/b", title: "B", times: [at(day: monday - 5, hour: 9, minute: 0)]),
        ], now: now, timeZone: utc)
        #expect(suggestions.habits.map(\.entry.title) == ["A"])
        #expect(suggestions.habits.first?.days == 3)
    }

    @Test func treatsTimesAcrossMidnightAsClose() {
        let lateNight = at(day: monday + 1, hour: 0, minute: 10) // 火曜 0:10
        let nights = [1, 4, 5].map { at(day: monday + 1 - $0, hour: 23, minute: 50) } // 月・金・木の 23:50
        let suggestions = NewTabSuggestions.make(from: [entry("https://night.example/", times: nights)], now: lateNight, timeZone: utc)
        #expect(suggestions.habits.count == 1)
    }

    @Test func groupsFrequentPagesBySiteWithoutHabitsOrSearches() {
        let habitTimes = [3, 4, 5].map { at(day: monday - $0, hour: 9, minute: 0) }
        let suggestions = NewTabSuggestions.make(from: [
            entry("https://habit.example/", times: habitTimes, typed: 50),
            entry("https://habit.example/other", typed: 1),
            entry("https://notes.example/page-a", typed: 10),
            entry("https://notes.example/page-b", typed: 1),
            entry("https://www.google.com/search?q=x", typed: 99),
        ], now: now, timeZone: utc)
        #expect(suggestions.frequent.map(\.site) == ["notes.example", "habit.example"], "ページの重みの合計で並べる")
        #expect(suggestions.frequent.first?.root.children.map(\.id) == ["/page-a", "/page-b"])
        #expect(suggestions.frequent.last?.root.entry == nil, "いつものに出したページは重ねない")
    }

    /// Notion のようにワークスペースの下にページが並ぶサイト。開いていない道筋は見出しとして残し、
    /// 一つのページにつながるだけの道筋は詰める。
    @Test func nestsPagesByTheirPath() throws {
        let suggestions = NewTabSuggestions.make(from: [
            entry("https://www.notion.so/", title: "Notion", typed: 1),
            entry("https://www.notion.so/team/%E8%AD%B0%E4%BA%8B%E9%8C%B2-1", title: "議事録", typed: 9),
            entry("https://www.notion.so/team/Design-2", title: "設計メモ", typed: 5),
            entry("https://www.notion.so/team/Design-2?pvs=4", title: "設計メモ（別の見た目）", typed: 1),
            entry("https://www.notion.so/me/deep/Diary-3", title: "日記", typed: 3),
        ], now: now, timeZone: utc)
        let site = try #require(suggestions.frequent.first)
        #expect(site.site == "www.notion.so")
        #expect(site.root.entry?.title == "Notion")
        let team = try #require(site.root.children.first)
        #expect(team.entry == nil && team.label == "team")
        #expect(team.children.map(\.title) == ["議事録", "設計メモ"])
        #expect(team.children.last?.children.map(\.title) == ["設計メモ（別の見た目）"], "クエリだけ違うページは下に置く")
        #expect(site.root.children.last?.title == "日記", "開いていない道筋が一つのページにつながるだけなら詰める")
    }

    @Test func listsPagesLeftSoonAfterFollowingALink() {
        let recent = at(day: monday - 1, hour: 12, minute: 0)
        let suggestions = NewTabSuggestions.make(from: [
            entry("https://a.example/read", title: "読みかけ", times: [recent], viewed: 30, links: 1),
            entry("https://a.example/done", title: "読んだ", times: [recent], viewed: 900, links: 1),
            entry("https://a.example/typed", title: "打った", times: [recent], viewed: 30),
            entry("https://a.example/often", title: "何度も", times: [recent], viewed: 30, links: 3, visits: 5),
            entry("https://a.example/marked", title: "ブックマーク", times: [recent], viewed: 30, links: 1),
            entry("https://a.example/old", title: "古い", times: [at(day: monday - 20, hour: 9, minute: 0)], viewed: 30, links: 1),
        ], now: now, timeZone: utc) { $0.path() == "/marked" }
        #expect(suggestions.unfinished.map(\.title) == ["読みかけ"])
    }
}
