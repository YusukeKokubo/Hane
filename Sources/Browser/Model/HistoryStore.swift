import ControlWire
import Foundation

/// 訪れたページ1件ぶんの記録。同じアドレスへの訪問はまとめて数える。
struct HistoryEntry: Codable, Equatable, Sendable {
    var url: URL
    var title: String
    var visitCount: Int
    /// アドレスバーに打って（または補われたまま確定して）訪れた回数。
    var typedCount: Int
    var lastVisit: Date
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

    private(set) var entries: [URL: HistoryEntry] = [:]

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
            NSLog("閲覧履歴を読めなかったため \(aside.path(percentEncoded: false)) に退避しました: \(error)")
        }
    }

    // MARK: 記録する

    /// 訪問を1回数える。補う意味のないアドレス（about: など）は記録しない。
    func recordVisit(to url: URL, typed: Bool, at date: Date = Date()) {
        guard Self.isRecordable(url) else { return }
        var entry = entries[url] ?? HistoryEntry(url: url, title: "", visitCount: 0, typedCount: 0, lastVisit: date)
        entry.visitCount += 1
        if typed { entry.typedCount += 1 }
        entry.lastVisit = date
        entries[url] = entry
        if entries.count > Self.limit { prune() }
        scheduleSave()
    }

    func setTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, var entry = entries[url], entry.title != title else { return }
        entry.title = title
        entries[url] = entry
        scheduleSave()
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
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Signposts.interval("閲覧履歴の書き出し") {
                let file = SavedFile(entries: entries.values.sorted { $0.lastVisit > $1.lastVisit })
                try JSONEncoder().encode(file).write(to: fileURL, options: .atomic)
            }
        } catch {
            NSLog("閲覧履歴を保存できませんでした: \(error)")
        }
    }

    // MARK: 内部

    private struct SavedFile: Codable {
        var version = 1
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
