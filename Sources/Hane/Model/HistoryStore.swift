import ControlWire
import Foundation

/// 訪問がどこから来たか。訪れた回数を道ごとに分けて数える。
enum VisitSource: Sendable {
    /// アドレスバーに打って（または補われたまま確定して）。検索語は含めない。
    case typed
    case bookmark
    /// ほかのアプリから既定のブラウザとして受けたリンク。
    case external
    /// ページの中のリンク（新しいタブに開いたものも含む）。
    case link
    /// 戻る・進む、読み込み直し、検索、スクリプトによる移動など。
    case other
}

/// 訪れたページ1件ぶんの記録。同じアドレスへの訪問はまとめて数える。
struct HistoryEntry: Codable, Equatable, Sendable {
    var url: URL
    var title: String
    var visitCount: Int
    /// アドレスバーに打って（または補われたまま確定して）訪れた回数。
    var typedCount: Int
    var bookmarkCount = 0
    var externalCount = 0
    var linkCount = 0
    var lastVisit: Date
    /// 最近訪れた時刻。古いものが先。毎日決まった頃に開くページを見つけるのに使う。
    /// 続けて訪れたもの（`HistoryStore.visitSpacing` 以内）は一度と数え、`HistoryStore.visitTimesKept` 件まで持つ。
    var visitTimes: [Date] = []
    /// 窓が前に出ていて、このページが選ばれていた時間の合計（秒）。
    var viewedSeconds: Double = 0

    init(url: URL, title: String, visitCount: Int, typedCount: Int, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisit = lastVisit
    }

    // 版1のファイルには後から足した項目がないので、無ければ既定の値で読む。
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(URL.self, forKey: .url)
        title = try values.decode(String.self, forKey: .title)
        visitCount = try values.decode(Int.self, forKey: .visitCount)
        typedCount = try values.decode(Int.self, forKey: .typedCount)
        bookmarkCount = try values.decodeIfPresent(Int.self, forKey: .bookmarkCount) ?? 0
        externalCount = try values.decodeIfPresent(Int.self, forKey: .externalCount) ?? 0
        linkCount = try values.decodeIfPresent(Int.self, forKey: .linkCount) ?? 0
        lastVisit = try values.decode(Date.self, forKey: .lastVisit)
        visitTimes = try values.decodeIfPresent([Date].self, forKey: .visitTimes) ?? []
        viewedSeconds = try values.decodeIfPresent(Double.self, forKey: .viewedSeconds) ?? 0
    }
}

/// アドレスバーで補う候補。`text` は入力欄にそのまま入れる文字列で、打った部分を頭に含む。
struct HistoryCompletion: Equatable, Sendable {
    var url: URL
    var text: String
}

/// 閲覧履歴。アドレスバーの入力を補うために使う。
///
/// 保存先を渡さなければメモリの中だけで持つ（開発用プロファイルとテスト）。
@MainActor
final class HistoryStore {
    /// これを超えたら、最後に訪れたのが古いものから捨てる。
    static let limit = 5000
    /// 訪れるたびに数千件を書き直さないよう、変化が落ち着くまで待ってからまとめて書く。
    private static let saveDelay: Duration = .seconds(5)
    /// 1件あたりに残す訪問の時刻の数。毎日開くページなら3週間ほどの癖が読める。
    static let visitTimesKept = 20
    /// これより間を置かずに訪れ直したもの（読み込み直しや戻る・進むの行き来）は、時刻を増やさない。
    static let visitSpacing: TimeInterval = 30 * 60
    /// 見ていた時間の一続きをこれより長くは数えない。窓を前に出したまま席を離れたときに膨らませないため。
    static let longestViewing: TimeInterval = 60 * 60

    private(set) var entries: [URL: HistoryEntry] = [:]
    /// 今見ているページと、見始めた時刻。
    private var viewing: (url: URL, since: Date)?

    private let fileURL: URL?
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let saved = try JSONDecoder().decode(SavedFile.self, from: data)
            entries = Dictionary(saved.entries.map { ($0.url, $0) }, uniquingKeysWith: { $1 })
        } catch {
            // 読めないファイルを次の保存で上書きすると中身を失うので、横へ退避してから空で始める。
            let aside = fileURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            AppLog.logger.error("閲覧履歴を読めなかったため \(aside.path(percentEncoded: false), privacy: .public) に退避しました: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: 記録する

    /// 訪問を1回数える。補う意味のないアドレス（about: など）は記録しない。
    func recordVisit(to url: URL, from source: VisitSource, at date: Date = Date()) {
        guard Self.isRecordable(url) else { return }
        var entry = entries[url] ?? HistoryEntry(url: url, title: "", visitCount: 0, typedCount: 0, lastVisit: date)
        entry.visitCount += 1
        switch source {
        case .typed: entry.typedCount += 1
        case .bookmark: entry.bookmarkCount += 1
        case .external: entry.externalCount += 1
        case .link: entry.linkCount += 1
        case .other: break
        }
        if entry.visitTimes.last.map({ date.timeIntervalSince($0) >= Self.visitSpacing }) ?? true {
            entry.visitTimes.append(date)
            if entry.visitTimes.count > Self.visitTimesKept {
                entry.visitTimes.removeFirst(entry.visitTimes.count - Self.visitTimesKept)
            }
        }
        entry.lastVisit = date
        entries[url] = entry
        if entries.count > Self.limit { prune() }
        scheduleSave()
    }

    /// 題名だけの変化では書き出しを予約しない。未読の数などで題名を書き換え続けるページがあり、
    /// そのたびに数千件を書き直すことになるため。題名は次の訪問か終了するときの書き出しに乗る。
    func setTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, var entry = entries[url], entry.title != title else { return }
        entry.title = title
        entries[url] = entry
    }

    /// 今見ているページが変わった。前に見ていたページに、見ていた時間を足す。
    /// 何も見ていない（窓が裏にいる、画面が眠った）ときは `nil` を渡す。
    ///
    /// 書き出しは予約しない。タブを移るたびに数千件を書き直さないためで、時間は次の訪問か終了するときの書き出しに乗る。
    func view(_ url: URL?, at date: Date = Date()) {
        if let viewing, viewing.url == url { return }
        closeViewing(at: date)
        viewing = url.map { ($0, date) }
    }

    /// 見ている途中の時間をここまでで締め、続きをここから数え直す。
    private func closeViewing(at date: Date) {
        guard let viewing else { return }
        self.viewing = nil
        let seconds = min(max(0, date.timeIntervalSince(viewing.since)), Self.longestViewing)
        guard seconds > 0, var entry = entries[viewing.url] else { return }
        entry.viewedSeconds += seconds
        entries[viewing.url] = entry
    }

    // MARK: 補う

    /// 打ちかけの文字列の続きとして、もっともありそうな訪問先を返す。
    ///
    /// 補うのは、打って訪れたことのあるページと、サイトの入口（パスのないアドレス）だけ。
    /// リンクで一度通っただけの深いページまで補うと、打つたびに思わぬ所へ飛ばされるため。
    func completion(for typed: String, now: Date = Date()) -> HistoryCompletion? {
        // 日本語入力の変換中の文字はアドレスに合わないので、ここで何も起きない。
        let needle = typed.lowercased()
        guard !needle.isEmpty else { return nil }
        var best: (completion: HistoryCompletion, score: Double)?
        for entry in entries.values where entry.typedCount > 0 || Self.isSiteRoot(entry.url) {
            guard let form = Self.forms(of: entry.url).first(where: { $0.count > needle.count && $0.lowercased().hasPrefix(needle) })
            else { continue }
            let score = Self.score(entry, now: now)
            let candidate = HistoryCompletion(url: entry.url, text: typed + form.dropFirst(typed.count))
            if let current = best,
               current.score > score || (current.score == score && current.completion.text.count <= candidate.text.count) {
                continue
            }
            best = (candidate, score)
        }
        return best?.completion
    }

    // MARK: 保存

    /// 待たずに書き出す。終了直前に呼ぶ。
    func saveNow(at date: Date = Date()) {
        pendingSave?.cancel()
        pendingSave = nil
        if let url = viewing?.url {
            closeViewing(at: date)
            viewing = (url, date)
        }
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Signposts.interval("閲覧履歴の書き出し") {
                let file = SavedFile(entries: entries.values.sorted { $0.lastVisit > $1.lastVisit })
                try JSONEncoder().encode(file).write(to: fileURL, options: .atomic)
            }
        } catch {
            AppLog.logger.error("閲覧履歴を保存できませんでした: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: 内部

    private struct SavedFile: Codable {
        /// 2 で、来た道ごとの回数、訪れた時刻、見ていた時間を足した。1 も読める。
        var version = 2
        var entries: [HistoryEntry]
    }

    private func scheduleSave() {
        guard fileURL != nil, pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// 上限を少し下回るまで、最後に訪れたのが古いものから捨てる。
    /// 1件増えるたびに並べ替えないよう、余裕を持って減らす。
    private func prune() {
        let keep = entries.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(Self.limit * 9 / 10)
        entries = Dictionary(keep.map { ($0.url, $0) }, uniquingKeysWith: { $1 })
    }

    private static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "file" { return true }
        return (scheme == "http" || scheme == "https") && url.host() != nil
    }

    private static func isSiteRoot(_ url: URL) -> Bool {
        (url.path().isEmpty || url.path() == "/") && url.query() == nil && url.fragment() == nil
    }

    /// 打ちかけの文字列と突き合わせる書き方。`https://` や `www.` を省いて打つことが多いので、
    /// 省いた形も並べる。サイトの入口は末尾の「/」も省く。
    static func forms(of url: URL) -> [String] {
        var full = url.absoluteString
        if isSiteRoot(url), full.hasSuffix("/") { full.removeLast() }
        var forms = [full]
        if let scheme = url.scheme, full.lowercased().hasPrefix(scheme.lowercased() + "://") {
            let bare = String(full.dropFirst(scheme.count + 3))
            forms.append(bare)
            if bare.lowercased().hasPrefix("www.") {
                forms.append(String(bare.dropFirst(4)))
            }
        }
        // 短い形から試し、打ったものに近い形で補う。
        return forms.reversed()
    }

    /// 打って訪れた回数を重く見て、しばらく訪れていないものは軽くする。
    private static func score(_ entry: HistoryEntry, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
        return Double(entry.typedCount * 5 + entry.visitCount) / (1 + days / 30)
    }
}
