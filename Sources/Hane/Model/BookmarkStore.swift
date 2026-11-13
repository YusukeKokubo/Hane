import ControlWire
import Foundation
import Observation

struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var url: URL
}

struct BookmarkFolder: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var bookmarks: [Bookmark] = []
}

/// バーに並ぶもの。フォルダの中にはブックマークしか入れられないので、階層は一段に限られる。
enum BookmarkItem: Identifiable, Equatable, Sendable {
    case bookmark(Bookmark)
    case folder(BookmarkFolder)

    var id: UUID {
        switch self {
        case .bookmark(let bookmark): bookmark.id
        case .folder(let folder): folder.id
        }
    }
}

extension BookmarkItem: Codable {
    // 保存ファイルを手で読み書きしやすいよう、`{"bookmark": {...}}` か `{"folder": {...}}` の形にする。
    private enum CodingKeys: String, CodingKey {
        case bookmark, folder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let folder = try container.decodeIfPresent(BookmarkFolder.self, forKey: .folder) {
            self = .folder(folder)
        } else {
            self = .bookmark(try container.decode(Bookmark.self, forKey: .bookmark))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bookmark(let bookmark): try container.encode(bookmark, forKey: .bookmark)
        case .folder(let folder): try container.encode(folder, forKey: .folder)
        }
    }
}

/// ブックマークとフォルダの並び。変えるたびにファイルへ書き出す。
///
/// 保存先を渡さなければメモリの中だけで持つ（開発用プロファイルとテスト）。
@MainActor
@Observable
final class BookmarkStore {
    private(set) var items: [BookmarkItem] = []

    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            items = try JSONDecoder().decode(SavedFile.self, from: data).items
        } catch {
            // 読めないファイルをそのまま上書きすると中身を失うので、横へ退避してから空で始める。
            let aside = fileURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            NSLog("ブックマークを読めなかったため \(aside.path(percentEncoded: false)) に退避しました: \(error)")
        }
    }

    // MARK: 調べる

    var folders: [BookmarkFolder] {
        items.compactMap { if case .folder(let folder) = $0 { folder } else { nil } }
    }

    /// バーに見える順のブックマーク。フォルダの中身はフォルダの位置に入る。
    var allBookmarks: [Bookmark] {
        items.flatMap { item -> [Bookmark] in
            switch item {
            case .bookmark(let bookmark): [bookmark]
            case .folder(let folder): folder.bookmarks
            }
        }
    }

    func bookmark(_ id: UUID) -> Bookmark? {
        allBookmarks.first { $0.id == id }
    }

    func folder(_ id: UUID) -> BookmarkFolder? {
        folders.first { $0.id == id }
    }

    func folder(named name: String) -> BookmarkFolder? {
        folders.first { $0.name == name }
    }

    func folderID(containing bookmarkID: UUID) -> UUID? {
        folders.first { $0.bookmarks.contains { $0.id == bookmarkID } }?.id
    }

    func bookmark(matching url: URL?) -> Bookmark? {
        guard let url else { return nil }
        return allBookmarks.first { $0.url.isSameDestination(as: url) }
    }

    // MARK: 変える

    /// ブックマークを足す。`folder` を省くと一段目に、`anchor` を省くと末尾に入る。
    @discardableResult
    func add(title: String, url: URL, folder folderID: UUID? = nil, before anchor: UUID? = nil) -> Bookmark {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = Bookmark(title: trimmed.isEmpty ? (url.host() ?? url.absoluteString) : trimmed, url: url)
        insert(bookmark, into: folderID, before: anchor)
        save()
        return bookmark
    }

    @discardableResult
    func addFolder(named name: String) -> BookmarkFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = BookmarkFolder(name: trimmed.isEmpty ? "新しいフォルダ" : trimmed)
        items.append(.folder(folder))
        save()
        return folder
    }

    /// ブックマークかフォルダの名前を変える。空の名前は受け付けない。
    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id, bookmark: { $0.title = trimmed }, folder: { $0.name = trimmed })
    }

    func setURL(_ id: UUID, to url: URL) {
        update(id, bookmark: { $0.url = url })
    }

    /// 並びを変える。ブックマークは `folder` に入れられるが、フォルダは常に一段目に置く。
    func move(_ id: UUID, into folderID: UUID?, before anchor: UUID? = nil) {
        guard id != anchor else { return }
        if let index = items.firstIndex(where: { $0.id == id }), case .folder = items[index] {
            let item = items.remove(at: index)
            items.insert(item, at: anchor.flatMap(topLevelIndex) ?? items.endIndex)
        } else if let bookmark = takeBookmark(id) {
            insert(bookmark, into: folderID, before: anchor)
        } else {
            return
        }
        save()
    }

    /// ブックマークかフォルダを消し、消えたブックマークのIDを返す。フォルダなら中身もすべて消える。
    @discardableResult
    func remove(_ id: UUID) -> [UUID] {
        if let index = items.firstIndex(where: { $0.id == id }), case .folder(let folder) = items[index] {
            items.remove(at: index)
            save()
            return folder.bookmarks.map(\.id)
        }
        guard takeBookmark(id) != nil else { return [] }
        save()
        return [id]
    }

    // MARK: 内部

    private struct SavedFile: Codable {
        var version = 1
        var items: [BookmarkItem]
    }

    /// 一段目での位置。フォルダの中のブックマークなら、そのフォルダの位置。
    private func topLevelIndex(of id: UUID) -> Int? {
        items.firstIndex { item in
            switch item {
            case .bookmark(let bookmark): bookmark.id == id
            case .folder(let folder): folder.id == id || folder.bookmarks.contains { $0.id == id }
            }
        }
    }

    private func insert(_ bookmark: Bookmark, into folderID: UUID?, before anchor: UUID?) {
        if let folderID,
           let index = items.firstIndex(where: { $0.id == folderID }),
           case .folder(var folder) = items[index] {
            let position = anchor.flatMap { anchor in folder.bookmarks.firstIndex { $0.id == anchor } }
            folder.bookmarks.insert(bookmark, at: position ?? folder.bookmarks.endIndex)
            items[index] = .folder(folder)
        } else {
            items.insert(.bookmark(bookmark), at: anchor.flatMap(topLevelIndex) ?? items.endIndex)
        }
    }

    private func takeBookmark(_ id: UUID) -> Bookmark? {
        for index in items.indices {
            switch items[index] {
            case .bookmark(let bookmark) where bookmark.id == id:
                items.remove(at: index)
                return bookmark
            case .folder(var folder):
                if let position = folder.bookmarks.firstIndex(where: { $0.id == id }) {
                    let bookmark = folder.bookmarks.remove(at: position)
                    items[index] = .folder(folder)
                    return bookmark
                }
            default:
                break
            }
        }
        return nil
    }

    private func update(
        _ id: UUID,
        bookmark change: (inout Bookmark) -> Void,
        folder changeFolder: (inout BookmarkFolder) -> Void = { _ in }
    ) {
        for index in items.indices {
            switch items[index] {
            case .bookmark(var bookmark) where bookmark.id == id:
                change(&bookmark)
                items[index] = .bookmark(bookmark)
            case .folder(var folder) where folder.id == id:
                changeFolder(&folder)
                items[index] = .folder(folder)
            case .folder(var folder):
                guard let position = folder.bookmarks.firstIndex(where: { $0.id == id }) else { continue }
                change(&folder.bookmarks[position])
                items[index] = .folder(folder)
            default:
                continue
            }
            save()
            return
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            // 手で直したり差分を見たりできるよう、整形して書く。
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(SavedFile(items: items)).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ブックマークを保存できませんでした: \(error)")
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
