import ControlWire
import Foundation
import Observation

struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var url: URL
    /// グループの固定なら、そのグループ。`nil` はどのグループを出していても並ぶブックマーク。
    var group: PinnedGroup?
}

/// グループの固定が属するグループ。`id` が `nil` ならグループに入っていないタブの並び。
/// `UUID??` にしないのは、JSON に書くと外側の `nil` と内側の `nil` を見分けられないため。
struct PinnedGroup: Codable, Hashable, Sendable {
    var id: UUID?
}

/// ブックマークの並び。変えるたびにファイルへ書き出す。
///
/// どのグループでも出るブックマークと、グループごとの固定を一つの並びで持つ。
/// 置き場（`Bookmark.group`）ごとに抜き出した順が、バーに並ぶ順になる。
///
/// 保存先を渡さなければメモリの中だけで持つ（開発用プロファイルとテスト）。
@MainActor
@Observable
final class BookmarkStore {
    /// バーに見える順。
    private(set) var bookmarks: [Bookmark] = []

    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            bookmarks = try JSONDecoder().decode(SavedFile.self, from: data).bookmarks
        } catch {
            // 読めないファイルをそのまま上書きすると中身を失うので、横へ退避してから空で始める。
            let aside = fileURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            AppLog.logger.error("ブックマークを読めなかったため \(aside.path(percentEncoded: false), privacy: .public) に退避しました: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: 調べる

    func bookmark(_ id: UUID) -> Bookmark? {
        bookmarks.first { $0.id == id }
    }

    /// その置き場のブックマーク。`nil` はどのグループでも出るもの。
    func bookmarks(in place: PinnedGroup?) -> [Bookmark] {
        bookmarks.filter { $0.group == place }
    }

    func bookmark(matching url: URL?) -> Bookmark? {
        guard let url else { return nil }
        return bookmarks.first { $0.url.isSameDestination(as: url) }
    }

    // MARK: 変える

    /// ブックマークを足す。`group` を渡せばそのグループの固定になる。`anchor` を省くと置き場の末尾に入る。
    @discardableResult
    func add(title: String, url: URL, group: PinnedGroup? = nil, before anchor: UUID? = nil) -> Bookmark {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = Bookmark(title: trimmed.isEmpty ? (url.host() ?? url.absoluteString) : trimmed, url: url, group: group)
        insert(bookmark, before: anchor)
        save()
        return bookmark
    }

    /// 名前を変える。空の名前は受け付けない。
    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    func setURL(_ id: UUID, to url: URL) {
        update(id) { $0.url = url }
    }

    /// 置き場と並びを変える。`anchor` を省くと置き場の末尾へ。`anchor` は移す先の置き場のものを渡す。
    func move(_ id: UUID, to group: PinnedGroup?, before anchor: UUID? = nil) {
        guard id != anchor, let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        var bookmark = bookmarks.remove(at: index)
        bookmark.group = group
        insert(bookmark, before: anchor)
        save()
    }

    /// 合うグループの固定を、グループに入っていないタブの並びの固定にする。グループを解いたときと、
    /// 閲覧状態から消えたグループの固定を拾うときに使う。
    func ungroupPins(where matches: (UUID) -> Bool) {
        var changed = false
        for index in bookmarks.indices {
            guard let id = bookmarks[index].group?.id, matches(id) else { continue }
            bookmarks[index].group = PinnedGroup(id: nil)
            changed = true
        }
        if changed { save() }
    }

    /// 消す。消したなら `true`。
    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        bookmarks.remove(at: index)
        save()
        return true
    }

    // MARK: 内部

    private struct SavedFile: Codable {
        var version = 2
        var bookmarks: [Bookmark]

        init(bookmarks: [Bookmark]) {
            self.bookmarks = bookmarks
        }

        // 版 1 はフォルダを持てたので、`items` に `{"bookmark": …}` か `{"folder": {"bookmarks": […]}}` が並ぶ。
        // フォルダはやめたので、中身をフォルダの位置へ並べて読む。
        private enum CodingKeys: String, CodingKey {
            case version, bookmarks, items
        }

        private struct LegacyItem: Decodable {
            struct Folder: Decodable {
                var bookmarks: [Bookmark]
            }

            var bookmark: Bookmark?
            var folder: Folder?
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let bookmarks = try container.decodeIfPresent([Bookmark].self, forKey: .bookmarks) {
                self.bookmarks = bookmarks
            } else {
                bookmarks = try container.decode([LegacyItem].self, forKey: .items).flatMap { item in
                    item.bookmark.map { [$0] } ?? item.folder?.bookmarks ?? []
                }
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(bookmarks, forKey: .bookmarks)
        }
    }

    /// 置き場ごとに抜き出して並べるので、末尾に入れるときは配列の末尾でよい。
    private func insert(_ bookmark: Bookmark, before anchor: UUID?) {
        let position = anchor.flatMap { anchor in bookmarks.firstIndex { $0.id == anchor } }
        bookmarks.insert(bookmark, at: position ?? bookmarks.endIndex)
    }

    private func update(_ id: UUID, _ change: (inout Bookmark) -> Void) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        change(&bookmarks[index])
        save()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            // 手で直したり差分を見たりできるよう、整形して書く。
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(SavedFile(bookmarks: bookmarks)).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.logger.error("ブックマークを保存できませんでした: \(String(describing: error), privacy: .public)")
        }
    }
}

extension URL {
    /// 末尾の「/」だけの違いは同じ行き先とみなす。
    /// `https://example.com` を読み込むと `https://example.com/` になるため。
    func isSameDestination(as other: URL) -> Bool {
        func normalized(_ url: URL) -> String {
            var text = url.absoluteString
            if text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return normalized(self) == normalized(other)
    }
}
