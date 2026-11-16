import SwiftUI

/// まっさらなタブの中身。閲覧履歴から、今の時間にいつも開くもの、よく行くもの、読みかけを並べる。
///
/// 並べるものは出したときに一度だけ数える（`NewTabSuggestions`）。開いたままにしていても数え直さない。
struct NewTabView: View {
    let tab: Tab
    let store: TabStore

    @State private var suggestions: NewTabSuggestions?
    @State private var shownAt = Date()

    var body: some View {
        ScrollView {
            if let suggestions {
                content(suggestions)
                    .frame(maxWidth: 1000)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            shownAt = Date()
            suggestions = NewTabSuggestions.make(from: store.history.entries.values, now: shownAt) { url in
                store.bookmarks.bookmark(matching: url) != nil
            }
        }
    }

    @ViewBuilder
    private func content(_ suggestions: NewTabSuggestions) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            if suggestions.isEmpty {
                Text("履歴がたまると、この時間にいつも開くページがここに出ます")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 80)
            }
            if !suggestions.habits.isEmpty {
                habits(suggestions.habits)
            }
            if !suggestions.frequent.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("よく行く").font(.title3.bold())
                        Text("開いた回数（打って開いたものは重く）と、最近かどうかで並べています")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(suggestions.frequent) { site in
                            SiteCard(site: site, icon: store.favicons.image(for: site.root.entry?.url ?? site.firstURL), open: open)
                        }
                    }
                }
            }
            if !suggestions.unfinished.isEmpty {
                LinkList(title: "読みかけ", note: "リンクから開いて、少しだけ見て離れたページ",
                         entries: suggestions.unfinished, open: open)
            }
        }
    }

    private func habits(_ habits: [NewTabSuggestions.Habit]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.title.bold())
                    Text("\(habits[0].dayKind == .weekday ? "平日" : "休日")のこの時間は、たいていこれを開いています")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("まとめて開く") { openAll(habits.map(\.entry.url)) }
                    .controlSize(.large)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                ForEach(habits, id: \.entry.url) { habit in
                    HabitCard(habit: habit, icon: store.favicons.image(for: habit.entry.url)) {
                        open(habit.entry.url)
                    }
                }
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: shownAt) {
        case 4..<10: "おはようございます"
        case 10..<17: "こんにちは"
        default: "こんばんは"
        }
    }

    private func open(_ url: URL) {
        tab.load(URLRequest(url: url))
    }

    /// 最初のページはこのタブで開き、残りは隣に裏のタブで並べる。隣へ順に差し込むので、後ろから開く。
    private func openAll(_ urls: [URL]) {
        guard let first = urls.first else { return }
        for url in urls.dropFirst().reversed() {
            store.open(URLRequest(url: url), inBackground: true)
        }
        open(first)
    }
}

private struct HabitCard: View {
    let habit: NewTabSuggestions.Habit
    let icon: NSImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                SiteIcon(url: habit.entry.url, icon: icon, size: 32)
                Text(displayTitle(of: habit.entry))
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(habit.dayKind == .weekday ? "平日" : "休日") \(habit.minute / 60):\(String(format: "%02d", habit.minute % 60))ごろ · \(habit.days)日")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(habit.entry.url.absoluteString)
    }
}

private struct LinkList: View {
    let title: String
    let note: String
    let entries: [HistoryEntry]
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(entries, id: \.url) { entry in
                Button {
                    open(entry.url)
                } label: {
                    Text(displayTitle(of: entry))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help(entry.url.absoluteString)
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// よく行くサイト一つ。開いたページを URL の道筋で字下げして並べる。
private struct SiteCard: View {
    let site: FrequentSite
    let icon: NSImage?
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let url = site.root.entry?.url ?? site.firstURL {
                    SiteIcon(url: url, icon: icon, size: 18)
                }
                if let entry = site.root.entry {
                    Button(site.site) { open(entry.url) }
                        .buttonStyle(.link)
                        .font(.headline)
                        .help(entry.url.absoluteString)
                } else {
                    Text(site.site).font(.headline)
                }
            }
            ForEach(site.rows, id: \.node.id) { row in
                Group {
                    if let entry = row.node.entry {
                        Button {
                            open(entry.url)
                        } label: {
                            Text(row.node.title).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        .help(entry.url.absoluteString)
                    } else {
                        Label(row.node.label, systemImage: "folder")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.leading, CGFloat(row.depth) * 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private extension FrequentSite {
    /// 入れ子を上から順に一列に並べたもの。`depth` は入口の下を 0 とした深さ。
    var rows: [(node: Node, depth: Int)] {
        func walk(_ nodes: [Node], _ depth: Int) -> [(node: Node, depth: Int)] {
            nodes.flatMap { [($0, depth)] + walk($0.children, depth + 1) }
        }
        return walk(root.children, 0)
    }

    /// 入口を開いていないときにアイコンを引くための、サイトのどれかのページ。
    var firstURL: URL? {
        rows.first { $0.node.entry != nil }?.node.entry?.url
    }
}

/// サイトのアイコン。覚えていなければ、サイト名の頭の文字で代える。
private struct SiteIcon: View {
    let url: URL
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Text(String((url.host() ?? url.lastPathComponent).replacing(/^www\./, with: "").prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size / 4).fill(Color.accentColor))
        }
    }
}

private func displayTitle(of entry: HistoryEntry) -> String {
    entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title
}
