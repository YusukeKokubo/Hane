import Foundation

/// 新しいタブに並べるページ。閲覧履歴から、今の時間にいつも開くもの、よく行くもの、読みかけを選ぶ。
///
/// 新しいタブを出したときに一度だけ数える。常駐して数え直すことはしない。
struct NewTabSuggestions: Equatable {
    /// 今の時間にいつも開いているページ。
    struct Habit: Equatable {
        var entry: HistoryEntry
        /// 「平日」「休日」のどちらで数えたか。
        var dayKind: DayKind
        /// いつも開く時刻（0時からの分）。
        var minute: Int
        /// 最近4週間のうち、この時間に開いた日数。
        var days: Int
    }

    enum DayKind: Equatable {
        case weekday, holiday
    }

    var habits: [Habit] = []
    var frequent: [HistoryEntry] = []
    var unfinished: [HistoryEntry] = []

    var isEmpty: Bool { habits.isEmpty && frequent.isEmpty && unfinished.isEmpty }

    /// 今の時刻からこれだけ前後に開いていれば、この時間に開いたと数える。
    static let habitWindowMinutes = 45
    /// この日数より前の訪問は、癖として数えない。
    static let habitLookbackDays = 28
    /// これだけの日数この時間に開いていれば、いつも開くものとして出す。
    static let habitMinimumDays = 3
    /// 読みかけとして出すのは、これより短く見て離れたページ。
    static let unfinishedViewLimit: TimeInterval = 120
    static let unfinishedLookbackDays = 7

    /// `isBookmarked` はブックマーク済みのページか。読みかけから外す。
    static func make(
        from entries: some Collection<HistoryEntry>,
        now: Date,
        timeZone: TimeZone = .current,
        isBookmarked: (URL) -> Bool = { _ in false }
    ) -> NewTabSuggestions {
        let clock = LocalClock(timeZone: timeZone, now: now)
        let habits = Self.habits(in: entries, clock: clock)
        let shown = Set(habits.map { $0.entry.url.host() ?? $0.entry.url.absoluteString })
        return NewTabSuggestions(
            habits: habits,
            frequent: Self.frequent(in: entries, now: now, excludingHosts: shown),
            unfinished: Self.unfinished(in: entries, now: now, isBookmarked: isBookmarked)
        )
    }

    // MARK: いつもの

    /// サイトごとにまとめて数える。チャットやメールのように開くたびにアドレスが変わるサイトがあるため。
    /// 出すのは、そのサイトでこの時間にいちばんよく開いたページ。
    private static func habits(in entries: some Collection<HistoryEntry>, clock: LocalClock) -> [Habit] {
        let kind = clock.dayKind(clock.today)
        let since = clock.today - habitLookbackDays
        // サイトごとに、この時間に開いた日と時刻、そのサイトの中でいちばんよく開いたページ。
        var bySite: [String: (days: Set<Int>, minutes: [Int], best: HistoryEntry, bestDays: Int)] = [:]
        for entry in entries {
            guard !AddressResolver.isSearch(entry.url) else { continue }
            var days = Set<Int>()
            var minutes: [Int] = []
            for time in entry.visitTimes {
                let (day, minute) = clock.split(time)
                guard day >= since, clock.dayKind(day) == kind,
                      LocalClock.distance(minute, clock.minute) <= habitWindowMinutes
                else { continue }
                days.insert(day)
                minutes.append(minute)
            }
            guard !days.isEmpty else { continue }
            let site = entry.url.host() ?? entry.url.absoluteString
            if var current = bySite[site] {
                current.days.formUnion(days)
                current.minutes += minutes
                if days.count > current.bestDays { (current.best, current.bestDays) = (entry, days.count) }
                bySite[site] = current
            } else {
                bySite[site] = (days, minutes, entry, days.count)
            }
        }
        return bySite.values
            .filter { $0.days.count >= habitMinimumDays }
            .map { Habit(entry: $0.best, dayKind: kind, minute: median($0.minutes), days: $0.days.count) }
            .sorted { ($0.minute, -$0.days) < ($1.minute, -$1.days) }
            .prefix(8)
            .map(\.self)
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: よく行く

    /// アドレスバーで補う候補と同じ重みで、サイトごとに一つずつ。
    private static func frequent(in entries: some Collection<HistoryEntry>, now: Date, excludingHosts: Set<String>) -> [HistoryEntry] {
        var best: [String: (entry: HistoryEntry, score: Double)] = [:]
        for entry in entries where !AddressResolver.isSearch(entry.url) {
            let site = entry.url.host() ?? entry.url.absoluteString
            guard !excludingHosts.contains(site) else { continue }
            let score = HistoryStore.score(entry, now: now)
            if let current = best[site], current.score >= score { continue }
            best[site] = (entry, score)
        }
        return best.values.sorted { $0.score > $1.score }.prefix(6).map(\.entry)
    }

    // MARK: 読みかけ

    /// リンクから開いて、少しだけ見て離れたページ。何度も開いたページは読みかけと見ない。
    private static func unfinished(
        in entries: some Collection<HistoryEntry>,
        now: Date,
        isBookmarked: (URL) -> Bool
    ) -> [HistoryEntry] {
        let since = now.addingTimeInterval(-Double(unfinishedLookbackDays) * 86_400)
        return entries
            .filter { entry in
                entry.linkCount > 0 && entry.visitCount <= 2 && entry.lastVisit >= since
                    && entry.viewedSeconds > 0 && entry.viewedSeconds < unfinishedViewLimit
                    && !entry.title.isEmpty && !AddressResolver.isSearch(entry.url) && !isBookmarked(entry.url)
            }
            .sorted { $0.lastVisit > $1.lastVisit }
            .prefix(5)
            .map(\.self)
    }
}

/// 時刻を「その土地の何日目の何分」に分ける。数千件の時刻を `Calendar` で分けると重いので、時差を足して割るだけにする。
/// 夏時間の切り替わりの前後で1時間ずれることがあるが、「何時ごろ」を見るには足りる。
struct LocalClock {
    let offset: Int
    let today: Int
    let minute: Int

    init(timeZone: TimeZone, now: Date) {
        offset = timeZone.secondsFromGMT(for: now)
        let seconds = Int(now.timeIntervalSince1970.rounded(.down)) + offset
        today = seconds.floorDiv(86_400)
        minute = (seconds - today * 86_400) / 60
    }

    func split(_ date: Date) -> (day: Int, minute: Int) {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down)) + offset
        let day = seconds.floorDiv(86_400)
        return (day, (seconds - day * 86_400) / 60)
    }

    /// 1970年1月1日は木曜日。祝日は数えない。
    func dayKind(_ day: Int) -> NewTabSuggestions.DayKind {
        let weekday = (day + 4).floorMod(7) // 0 が日曜
        return weekday == 0 || weekday == 6 ? .holiday : .weekday
    }

    /// 一日の中の二つの時刻の近さ（分）。日をまたいで近いもの（23:50 と 0:10）も近いと見る。
    static func distance(_ a: Int, _ b: Int) -> Int {
        let raw = abs(a - b)
        return min(raw, 24 * 60 - raw)
    }
}

private extension Int {
    func floorDiv(_ divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    func floorMod(_ divisor: Int) -> Int {
        self - floorDiv(divisor) * divisor
    }
}
