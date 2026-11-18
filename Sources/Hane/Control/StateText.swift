import AppKit
import ControlWire
import Foundation
import OSLog

/// アプリの状態（タブ、窓まわり、ブックマーク、プロファイル、ダウンロード、記録、計測）を、命令の答えの文字に整える。
///
/// 読むだけで、状態は変えない。
@MainActor
final class StateText {
    private let model: BrowserModel
    /// アプリの起動とほぼ同時に作られるので、起動した時刻として使う。
    private let launchedAt = Date()

    init(model: BrowserModel) {
        self.model = model
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: タブ

    func tab(_ tab: Tab) -> String {
        let mark = tab.id == model.store?.selectedID ? "*" : " "
        let url = tab.url?.absoluteString ?? "(空)"
        let loading = tab.isLoading ? " [loading]" : tab.isAsleep ? " [asleep]" : ""
        let icon = tab.favicon != nil ? " [icon]" : ""
        let bookmark = model.store.flatMap { store in store.bookmarkID(of: tab).flatMap(store.bookmarks.bookmark) }.map { " [bookmark: \($0.title)]" } ?? ""
        return "\(mark) tab \(tab.number): \(tab.title) — \(url)\(loading)\(icon)\(bookmark)"
    }

    func tabs(of store: TabStore) -> String {
        store.allTabs.map(tab).joined(separator: "\n")
    }

    /// 組の一覧。出している組に * 、バーに並べている組に [bar] を付ける。
    func groups(of store: TabStore) -> String {
        let ungrouped = (store.currentGroupID == nil ? "*" : " ") + " (グループなし) — \(store.tabs(in: nil).count) tabs"
        return ([ungrouped] + store.groups.map { group in
            (store.currentGroupID == group.id ? "*" : " ") + " \(group.name) — \(store.tabs(in: group.id).count) tabs"
                + (group.showsInBar ? " [bar]" : "")
        }).joined(separator: "\n")
    }

    func history(of store: TabStore, limit: Int) -> String {
        let recent = store.history.entries.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(limit)
        guard !recent.isEmpty else { return "（履歴なし）" }
        return recent.map { entry in
            let sources = [("bookmark", entry.bookmarkCount), ("external", entry.externalCount), ("link", entry.linkCount)]
                .filter { $0.1 > 0 }.map { " \($0.0) \($0.1)" }.joined()
            let viewed = entry.viewedSeconds > 0 ? " viewed \(String(format: "%.1f", entry.viewedSeconds))s" : ""
            let times = entry.visitTimes.count > 1
                ? "\n    at " + entry.visitTimes.map(Self.day.string(from:)).joined(separator: ", ")
                : ""
            return "\(Self.clock.string(from: entry.lastVisit)) typed \(entry.typedCount) visits \(entry.visitCount)\(sources)\(viewed)  "
                + "\(entry.title.isEmpty ? "(無題)" : entry.title) — \(entry.url.absoluteString)" + times
        }.joined(separator: "\n")
    }

    /// ページが出した記録（console など）の、新しいものから `limit` 件。
    func logs(of tab: Tab, limit: Int) -> String {
        let entries = tab.log.entries.suffix(limit)
        let listing = entries.isEmpty
            ? "（記録なし）"
            : entries.map { "\(Self.clock.string(from: $0.date)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
        return self.tab(tab) + "\n" + listing
    }

    // MARK: 窓まわり

    /// ウインドウの枠まわり（ページの外側）が今どう見えているか。
    func ui() -> String {
        var lines = ["instance: \(BrowserInstance.label), profile: \(model.current ?? "(窓なし)")", build(),
                     "window frame: " + windowFrame()]
        guard let store = model.store else {
            lines.append("（プロファイルを出している窓がない）")
            return lines.joined(separator: "\n")
        }
        if let tab = store.selected {
            let state: (Bool) -> String = { $0 ? "enabled" : "disabled" }
            lines.append("window title: \(tab.title)")
            lines.append("address bar: \"\(store.addressBar.text)\"" + (store.addressBar.isFocused ? " (focused)" : "")
                + (store.addressBar.completion.map { " completion=\"\($0)\"" } ?? ""))
            lines.append("buttons: back=\(state(tab.canGoBack)) forward=\(state(tab.canGoForward)) "
                + (tab.isLoading ? "stop=enabled" : "reload=\(state(tab.hasContent))"))
            lines.append("page: " + (tab.hasContent
                ? (tab.isLoading ? "loading \(Int(tab.estimatedProgress * 100))%" : "loaded")
                : "empty"))
            if let failure = tab.failure {
                lines.append("failure shown: \(failure)")
            }
        }
        lines.append("bookmarks bar: " + bookmarkBar(of: store))
        if !store.groups.isEmpty {
            let bar = store.groups.filter(\.showsInBar).map { "[" + (store.currentGroupID == $0.id ? "*" : "") + $0.name + "]" }
            lines.append("group: " + (store.currentGroup?.name ?? "(グループなし)")
                + (bar.isEmpty ? "" : "  bar: " + bar.joined(separator: " ")))
        }
        for (_, kind) in WindowElements.windows(main: model.currentWindow).dropFirst() {
            lines.append("overlay: \(kind)（中身は ui-snapshot）")
        }
        lines.append("tabs (left to right):")
        lines.append(contentsOf: store.allTabs.map(tab))
        return lines.joined(separator: "\n")
    }

    /// 窓の大きさと位置、覚えている名前。窓の枠を戻す仕組みが効いているかを外から確かめるため。
    /// 位置は画面の左上からの距離で表す（AppKit の座標は左下から測るので向きを直す）。
    private func windowFrame() -> String {
        guard let window = WindowElements.windows(main: model.currentWindow).first?.window else { return "(なし)" }
        let frame = window.frame
        let screen = window.screen?.frame ?? .zero
        let name = window.frameAutosaveName.isEmpty ? "(覚えない)" : "\"\(window.frameAutosaveName)\""
        return "\(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.minX - screen.minX)), \(Int(screen.maxY - frame.maxY)))"
            + " on \(Int(screen.width))x\(Int(screen.height)) screen, remembered as \(name)"
    }

    /// バーの左側を、画面に出ている文字のとおりに一行で表す。
    /// 選ばれている項目には *、ページを開いている項目には (open) を付ける。
    private func bookmarkBar(of store: TabStore) -> String {
        guard !store.bookmarks.bookmarks.isEmpty else { return "(なし)" }
        return store.bookmarks.bookmarks.map { bookmark in
            let tab = store.bookmarkTabs[bookmark.id]
            let label = store.awayTitle(for: bookmark).map { "\(bookmark.title) / \($0)" } ?? bookmark.title
            return "[" + mark(tab) + label + (tab != nil ? " (open)" : "") + "]"
        }.joined(separator: " ")
    }

    // MARK: 実体と版

    /// 動いている実体と、その実行ファイルがいつ作られたか。
    ///
    /// 作り直したのに古い実体が動き続けていて（シートが出ていて終われなかったなど）、
    /// 古い版を確かめていたことがあった。起動のあとに作り直されていればそう書く。
    private func build() -> String {
        let built = Self.executableDate().map { Self.clock.string(from: $0) } ?? "?"
        return "app: pid \(getpid()), started \(Self.clock.string(from: launchedAt)), built \(built)"
            + (isStaleBuild ? "（起動したあとに作り直されている。古い版が動いているので quit して起動し直すこと）" : "")
    }

    private var isStaleBuild: Bool {
        Self.executableDate().map { $0 > launchedAt } ?? false
    }

    private static func executableDate() -> Date? {
        guard let path = Bundle.main.executableURL?.path(percentEncoded: false) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: ブックマーク

    /// ブックマークを番号つきで一覧する。番号はバーの左からの通し番号。
    func bookmarks(of store: TabStore) -> String {
        let lines = store.bookmarks.bookmarks.enumerated().map { index, bookmark in
            let tab = store.bookmarkTabs[bookmark.id]
            let open = tab.map { " (open: tab \($0.number))" } ?? ""
            return "\(mark(tab).isEmpty ? " " : "*") \(index + 1) \(bookmark.title) — \(bookmark.url.absoluteString)\(open)"
        }
        return lines.isEmpty ? "（ブックマークなし）" : lines.joined(separator: "\n")
    }

    /// `bookmarks` の一覧に出る番号を、ブックマークのIDに引き直す。
    static func bookmarkID(_ number: Int, in store: TabStore) throws -> UUID {
        let bookmarks = store.bookmarks.bookmarks
        guard bookmarks.indices.contains(number - 1) else {
            throw ControlError("ブックマーク \(number) はない。`bookmarks` で一覧を見ること。")
        }
        return bookmarks[number - 1].id
    }

    private func mark(_ tab: Tab?) -> String {
        tab != nil && tab?.id == model.store?.selectedID ? "*" : ""
    }

    // MARK: プロファイル、ダウンロード、広告ブロック

    /// プロファイルの一覧。今のもの（外部操作の相手）に *、ほかの窓に出ているものに + を付ける。
    func profiles() -> String {
        var lines = ["instance: \(BrowserInstance.label) (" + (model.isPersistent ? "保存する" : "使い捨て") + ")"]
        for name in model.names {
            let mark = name == model.current ? "* " : model.isShown(name) ? "+ " : "  "
            lines.append(mark + BrowserModel.title(for: name)
                + (name == BrowserProfile.defaultName ? " (default)" : ""))
        }
        if !model.isPersistent {
            lines.append("（使い捨ての実体なので、登録した一覧は見せない。作ったものはこの実体の中だけで、何も保存しない）")
        }
        return lines.joined(separator: "\n")
    }

    /// ダウンロードの一覧。始まった順。
    func downloads() -> String {
        let downloads = model.downloads
        var lines = ["folder: \(downloads.directory.path(percentEncoded: false))"]
        if downloads.items.isEmpty { lines.append("（ダウンロードなし）") }
        for item in downloads.items {
            let state = switch item.state {
            case .running: "running" + (item.fraction.map { " \(Int($0 * 100))%" } ?? "")
            case .finished: "finished"
            case .failed(let message): "failed: \(message)"
            case .cancelled: "cancelled"
            }
            lines.append("[\(state)] \(item.fileName)"
                + (item.destination.map { " -> \($0.path(percentEncoded: false))" } ?? "")
                + (item.source.map { " from \($0.absoluteString)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    func adBlock(_ blocker: ContentBlocker) -> String {
        var lines: [String] = []
        switch blocker.filterState {
        case .unavailable: lines.append("filters: unavailable（同梱のリストがない）")
        case .preparing: lines.append("filters: preparing")
        case .ready(let rules?, let skipped?): lines.append("filters: ready (\(rules) rules, \(skipped) skipped)")
        case .ready: lines.append("filters: ready (compiled earlier)")
        case .failed(let message): lines.append("filters: failed: \(message)")
        }
        let elements = blocker.hidden.elements
        let sites = Set(elements.map(\.site))
        lines.append("hidden elements: \(elements.count) on \(sites.count) site(s)")
        if let tab = model.store?.selected, let site = tab.url.flatMap(HiddenElementStore.site(for:)) {
            let selectors = blocker.hidden.selectors(on: site)
            lines.append("this site: \(site) (\(selectors.count))")
            lines += selectors.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 計測

    /// プロセスごとの資源を `seconds` 秒測り、表か JSON にする。窓がなくても、プロセスの資源は測る。
    func stats(seconds: Double, json: Bool) async throws -> String {
        let all = model.store?.allTabs ?? []
        let pages = Dictionary(grouping: all.filter(\.hasContent)) { $0.page.flatMap(PageProcess.identifier(of:)) }
        let byProcess = pages.reduce(into: [pid_t: [Int]]()) { result, entry in
            if let pid = entry.key { result[pid] = entry.value.map(\.number) }
        }
        let report = await ProcessStats.measure(for: .milliseconds(Int(seconds * 1000)), tabs: byProcess)
        let tabs = StatsTabs(
            total: all.count, withContent: all.count { $0.hasContent }, asleep: all.count { $0.isAsleep },
            bookmarkPages: model.store?.bookmarkTabs.count ?? 0)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(StatsOutput(report: report, tabs: tabs))
            return String(decoding: data, as: UTF8.self)
        }
        return ProcessStats.table(report)
            + "\ntabs: \(tabs.total)（うちページあり \(tabs.withContent)、眠っている \(tabs.asleep)、ブックマークのページ \(tabs.bookmarkPages)）"
            + (isStaleBuild ? "\n" + build() : "")
    }

    // MARK: アプリ自身の記録

    /// アプリが `AppLog` で出した記録の、新しいものから `limit` 件。`seconds` がなければ起動してからの分。
    func appLogs(seconds: Double?, limit: Int) async throws -> String {
        // 読むのは命令のときだけ。`OSLogStore` は一度に 1 秒近くかかり、メインスレッドで読むと窓が止まる。
        let since = seconds.map { Date().addingTimeInterval(-$0) } ?? launchedAt.addingTimeInterval(-1)
        let lines = try await Task.detached { try Self.readAppLog(since: since) }.value.suffix(limit)
            .map { "\(Self.clock.string(from: $0.date)) \($0.text)" }
        return "app: pid \(getpid())\n" + (lines.isEmpty ? "（記録なし）" : lines.joined(separator: "\n"))
    }

    /// このプロセスが `AppLog` で出した記録を、古い順に。
    ///
    /// 記録を別に溜めず、統一ログからこのプロセスの分を読む。`subsystem` で絞るのは、WebKit など
    /// システムの枠組みが同じプロセスの名で大量に出す記録に埋もれないため。
    nonisolated private static func readAppLog(since: Date) throws -> [(date: Date, text: String)] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", AppLog.subsystem)
        let entries = try store.getEntries(at: store.position(date: since), matching: predicate)
        return entries.compactMap { entry in
            guard let entry = entry as? OSLogEntryLog else { return nil }
            let level = switch entry.level {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .error: "error"
            case .fault: "fault"
            default: "log"
            }
            return (entry.date, "[\(level)] \(entry.composedMessage)")
        }
    }
}

/// `stats --json` の出力。前後の計測を機械で引き比べるため。
private struct StatsOutput: Encodable {
    let report: ProcessStats.Report
    let tabs: StatsTabs
}

private struct StatsTabs: Encodable {
    let total: Int
    let withContent: Int
    let asleep: Int
    let bookmarkPages: Int
}
