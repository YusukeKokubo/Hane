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
    var frequent: [FrequentSite] = []
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
    /// よく行くに出すサイトの数と、1サイトあたりのページの数。
    static let frequentSiteLimit = 4
    static let frequentPagesPerSite = 8

    /// `isBookmarked` はブックマーク済みのページか。読みかけから外す。
    static func make(
        from entries: some Collection<HistoryEntry>,
        now: Date,
        timeZone: TimeZone = .current,
        isBookmarked: (URL) -> Bool = { _ in false }
    ) -> NewTabSuggestions {
        let clock = LocalClock(timeZone: timeZone, now: now)
        let habits = Self.habits(in: entries, clock: clock)
        let shown = Set(habits.map(\.entry.url))
        return NewTabSuggestions(
            habits: habits,
            frequent: Self.frequent(in: entries, now: now, excluding: shown),
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

    /// アドレスバーで補う候補と同じ重みで、サイトごとにページを選び、URL の道筋で入れ子にする。
    /// 同じサイトの別々のページ（Notion の各ページなど）を一つにまとめると、どれを開けばよいか分からなくなるため。
    /// サイトはページの重みの合計で並べる。いつものに出したページは重ねて出さない。
    private static func frequent(in entries: some Collection<HistoryEntry>, now: Date, excluding shown: Set<URL>) -> [FrequentSite] {
        var bySite: [String: [(entry: HistoryEntry, score: Double)]] = [:]
        for entry in entries where !AddressResolver.isSearch(entry.url) && !shown.contains(entry.url) {
            bySite[FrequentSite.site(of: entry.url), default: []].append((entry, HistoryStore.score(entry, now: now)))
        }
        return bySite
            .map { site, pages in (site: site, pages: pages, total: pages.reduce(0) { $0 + $1.score }) }
            .sorted { $0.total > $1.total }
            .prefix(frequentSiteLimit)
            .map { site in
                let pages = site.pages.sorted { $0.score > $1.score }.prefix(frequentPagesPerSite)
                return FrequentSite(site: site.site, pages: pages.map { ($0.entry, $0.score) })
            }
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

/// よく行くサイト一つ。開いたページを URL の道筋で入れ子にして持つ。
struct FrequentSite: Equatable, Identifiable {
    /// 入れ子の一段。開いたページなら `entry` を持ち、ページの間をつなぐだけの道筋なら持たない。
    struct Node: Equatable, Identifiable {
        /// サイトの中での道筋。並びの中で一つに決まる。
        var id: String
        /// 道筋の一区切り。開いたページなら題名を使う（`title`）。
        var label: String
        var entry: HistoryEntry?
        var children: [Node] = []
        /// この下でいちばん重いページの重み。兄弟の並び順に使う。
        var score: Double = 0

        var title: String {
            guard let entry, !entry.title.isEmpty else { return label }
            return entry.title
        }
    }

    var site: String
    /// サイトの入口。入口のページを開いていれば `entry` を持つ。
    var root: Node

    var id: String { site }

    static func site(of url: URL) -> String {
        url.host() ?? url.scheme ?? url.absoluteString
    }

    /// 重いものから順に渡す。同じ道筋に二つ来たら（クエリだけ違うなど）、先の方を残す。
    init(site: String, pages: [(entry: HistoryEntry, score: Double)]) {
        self.site = site
        var root = Node(id: "", label: site)
        for page in pages {
            root.insert(Self.segments(of: page.entry.url)[...], entry: page.entry, score: page.score)
        }
        root.children = root.children.map { $0.tidied() }.sorted { $0.score > $1.score }
        self.root = root
    }

    /// 道筋の区切り。クエリは別のページとして最後の区切りに足す。フラグメントは同じページと見る。
    static func segments(of url: URL) -> [String] {
        var segments = url.pathComponents.filter { $0 != "/" }
        if let query = url.query(), !query.isEmpty { segments.append("?" + query) }
        return segments
    }
}

private extension FrequentSite.Node {
    mutating func insert(_ segments: ArraySlice<String>, entry: HistoryEntry, score: Double) {
        self.score = max(self.score, score)
        guard let first = segments.first else {
            if self.entry == nil { self.entry = entry }
            return
        }
        let childID = id + "/" + first
        if let index = children.firstIndex(where: { $0.id == childID }) {
            children[index].insert(segments.dropFirst(), entry: entry, score: score)
        } else {
            var child = Self(id: childID, label: first.removingPercentEncoding ?? first)
            child.insert(segments.dropFirst(), entry: entry, score: score)
            children.append(child)
        }
    }

    /// 開いていない道筋が一つのページにつながるだけなら、間を詰める。重いものから並べる。
    func tidied() -> Self {
        var node = self
        while node.entry == nil, node.children.count == 1 {
            let only = node.children[0]
            node = Self(id: only.id, label: only.entry == nil ? node.label + "/" + only.label : only.label,
                        entry: only.entry, children: only.children, score: only.score)
        }
        node.children = node.children.map { $0.tidied() }.sorted { $0.score > $1.score }
        return node
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
