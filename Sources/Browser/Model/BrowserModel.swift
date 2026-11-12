import ControlWire
import Foundation
import Observation
import WebKit

/// アプリ全体の状態。プロファイルの一覧と、今開いているプロファイルのタブ管理を持つ。
///
/// 一つの実体の中で開くプロファイルは一度に一つだけで、窓・メニュー・外部操作はここを通して今の `TabStore` を見る。
/// 起動時に渡した `TabStore` を掴み続けると、切り替えたあと古いプロファイルを相手にしてしまうので、使うたびに `store` を読むこと。
@MainActor
@Observable
final class BrowserModel {
    /// 今開いているプロファイル。
    private(set) var current: String
    /// メニューに並べる順。`default` が先頭で、続いて登録した順（使い捨ての実体では作った順）。
    private(set) var names: [String]
    /// 今のプロファイルのタブ管理。切り替えると作り直す。
    private(set) var store: TabStore
    /// 新しいプロファイルの名前を尋ねているか。
    var isCreating = false
    /// 利用者に見せる失敗。
    var failure: String?

    @ObservationIgnored let contentBlocker: ContentBlocker?
    /// 持ち物の根元。使い捨ての実体では `nil` で、何も保存せず、作った名前はこの実体の中にだけ持つ。
    @ObservationIgnored private let directory: URL?
    /// サイトデータを保存するか。テストでは保存する置き場を試しても、WebKit の置き場は作らない。
    @ObservationIgnored private let keepsSiteData: Bool
    @ObservationIgnored private var registered: [ProfileRegistry.Entry]
    @ObservationIgnored private var temporaryNames: [String] = []
    /// 一度開いたプロファイルの持ち物。離れても捨てずに、戻ったときに同じものを使う。
    /// 同じファイルを二つのストアが書き合わないためと、使い捨ての実体でも閲覧状態を戻せるようにするため。
    @ObservationIgnored private var opened: [String: ProfileData] = [:]

    /// `directory` は持ち物の根元（`default` の持ち物と一覧をここに、ほかは `profiles/<名前>/` に置く）。
    init(directory: URL?, contentBlocker: ContentBlocker?, keepsSiteData: Bool = true) {
        self.directory = directory
        self.contentBlocker = contentBlocker
        self.keepsSiteData = keepsSiteData
        let registry = directory.flatMap { try? ProfileRegistry.load(from: ProfileRegistry.fileURL(in: $0)) } ?? ProfileRegistry()
        let names = [BrowserProfile.defaultName] + registry.profiles.map(\.name)
        let start = registry.lastOpened.flatMap { names.contains($0) ? $0 : nil } ?? BrowserProfile.defaultName
        registered = registry.profiles
        self.names = names
        current = start
        let data = ProfileData(
            name: start, entry: registry.profiles.first { $0.name == start }, directory: directory, keepsSiteData: keepsSiteData)
        opened = [start: data]
        store = Self.makeStore(with: data, contentBlocker: contentBlocker)
    }

    /// テスト用。渡したタブ管理を `default` として持つ、使い捨ての実体のモデル。
    init(store: TabStore) {
        directory = nil
        keepsSiteData = false
        contentBlocker = store.contentBlocker
        registered = []
        names = [BrowserProfile.defaultName]
        current = BrowserProfile.defaultName
        self.store = store
    }

    /// 普段使いの実体は登録した一覧を使い、使い捨ての実体は見せない（そこから持ち主のデータに触れないため）。
    static func forInstance(contentBlocker: ContentBlocker?) -> BrowserModel {
        BrowserModel(directory: BrowserInstance.dataDirectory, contentBlocker: contentBlocker)
    }

    var isPersistent: Bool { directory != nil }

    private var registryURL: URL? { directory.map(ProfileRegistry.fileURL(in:)) }

    static func title(for name: String) -> String {
        name == BrowserProfile.defaultName ? "標準" : name
    }

    // MARK: 作る・移る

    /// プロファイルを作って一覧に足す。開くのは別（`switchTo`）。
    func create(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let registryURL {
            // 読めない一覧を空として上書きしないよう、書く直前に読み直す（読めなければ投げる）。
            var registry = try ProfileRegistry.load(from: registryURL)
            try registry.add(name)
            try registry.save(to: registryURL)
            registered = registry.profiles
        } else {
            if let problem = BrowserProfile.problem(withName: name) { throw ProfileError("使えない名前: \(problem)") }
            guard !names.contains(name) else { throw ProfileError("「\(name)」はもうある") }
            temporaryNames.append(name)
        }
        names = [BrowserProfile.defaultName] + registered.map(\.name) + temporaryNames
        return name
    }

    /// そのプロファイルへ移る。移ったら `true`、もうそこにいたら `false`。
    ///
    /// 今のプロファイルの閲覧状態を書き出してからページをすべて閉じ、移る先のタブを閲覧状態から戻す。
    /// 離れたプロファイルのページは生かしておかない（切り替えは頻繁ではないので、戻ったときに選んでいたページだけ読み込み直す）。
    @discardableResult
    func switchTo(_ name: String) throws -> Bool {
        guard names.contains(name) else { throw ProfileError("「\(name)」というプロファイルはない") }
        guard name != current else { return false }
        store.shutDown()
        // 小窓は開いたプロファイルのサイトデータを使っているので、残すと別のプロファイルの中に紛れる。
        PopupWindows.close(openedBy: store)
        current = name
        store = makeStore(for: name)
        remember(name)
        return true
    }

    /// メニューやキーから。失敗はアラートで見せる。
    func open(_ name: String) {
        do {
            try switchTo(name)
        } catch {
            failure = String(describing: error)
        }
    }

    /// メニューやシートから。失敗はアラートで見せる。
    func createAndOpen(_ rawName: String) {
        do {
            try switchTo(try create(rawName))
        } catch {
            failure = String(describing: error)
        }
    }

    /// 終了直前に呼ぶ。閲覧状態と履歴は変化から少し遅れて書き出すので、最後の変化を取りこぼさないよう書く。
    func saveBeforeQuit() {
        store.saveSession()
        for data in opened.values {
            data.history.saveNow()
        }
    }

    // MARK: 内部

    private func makeStore(for name: String) -> TabStore {
        let data = opened[name] ?? ProfileData(
            name: name, entry: registered.first { $0.name == name }, directory: directory, keepsSiteData: keepsSiteData)
        opened[name] = data
        return Self.makeStore(with: data, contentBlocker: contentBlocker)
    }

    private static func makeStore(with data: ProfileData, contentBlocker: ContentBlocker?) -> TabStore {
        TabStore(
            factory: PageFactory(dataStore: data.dataStore, contentBlocker: contentBlocker),
            bookmarks: data.bookmarks,
            history: data.history,
            session: data.session
        )
    }

    /// 次の起動で同じプロファイルを開くために覚える。
    private func remember(_ name: String) {
        guard let registryURL else { return }
        do {
            var registry = try ProfileRegistry.load(from: registryURL)
            registry.lastOpened = name == BrowserProfile.defaultName ? nil : name
            try registry.save(to: registryURL)
        } catch {
            NSLog("最後に開いたプロファイルを覚えられませんでした: \(error)")
        }
    }
}

/// プロファイル一つぶんの持ち物。
@MainActor
final class ProfileData {
    let dataStore: WKWebsiteDataStore
    let bookmarks: BookmarkStore
    let history: HistoryStore
    let session: SessionStore

    /// 持ち物の根元（`base`）があればプロファイルの置き場に保存し、サイトデータは `default` なら WebKit の既定、
    /// 登録したものは一覧に残した識別子で分ける。使い捨ての実体ではどれもメモリの中だけに持つ。
    init(name: String, entry: ProfileRegistry.Entry?, directory base: URL?, keepsSiteData: Bool) {
        let directory = base.map { BrowserProfile.directory(for: name, in: $0) }
        let persistent = base != nil && keepsSiteData
        if persistent, name == BrowserProfile.defaultName {
            dataStore = .default()
        } else if persistent, let entry {
            dataStore = WKWebsiteDataStore(forIdentifier: entry.dataStore)
        } else {
            dataStore = .nonPersistent()
        }
        bookmarks = BookmarkStore(fileURL: directory?.appending(path: "bookmarks.json"))
        history = HistoryStore(fileURL: directory?.appending(path: "history.json"))
        session = SessionStore(fileURL: directory?.appending(path: "session.json"))
    }
}

/// 同じ実体がもう動いていれば、そちらを前に出して、この実体は起動をやめる。
///
/// 同じ実体を二つ動かすと、操作用ソケットを奪い合い、閲覧状態やブックマークを互いに上書きしてしまう。
enum RunningInstance {
    static func handOffIfAlreadyRunning() {
        guard let response = ControlSocket.send(["pid"], to: ControlSocket.path), response.ok else { return }
        if BrowserInstance.isDefault {
            _ = ControlSocket.send(["activate"], to: ControlSocket.path)
        }
        exit(0)
    }
}
