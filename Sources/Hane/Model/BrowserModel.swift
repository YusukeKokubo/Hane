import ControlWire
import Foundation
import Observation
import WebKit

/// アプリ全体の状態。プロファイルの一覧と、窓を開いているプロファイルごとのタブ管理を持つ。
///
/// プロファイルは窓一枚に一つずつ出し、同じプロファイルを二枚の窓には出さない（閲覧状態を書き合わないため）。
/// メニュー・外部操作は、最後に前へ出たプロファイルの窓（`current`）の `TabStore` を見る。
/// 起動時に渡した `TabStore` を掴み続けると、切り替えたあと古いプロファイルを相手にしてしまうので、使うたびに `store` を読むこと。
@MainActor
@Observable
final class BrowserModel {
    /// 最後に前へ出たプロファイルの窓のプロファイル。窓がなければ、最後に窓を閉じたプロファイル。
    private(set) var current: String
    /// メニューに並べる順。`default` が先頭で、続いて登録した順（使い捨ての実体では作った順）。
    private(set) var names: [String]
    /// `current` のタブ管理。
    private(set) var store: TabStore
    /// 開いている本体の窓。開いた順。
    private(set) var windows: [BrowserWindowSlot] = []
    /// 最後に前へ出た窓。プロファイルを選ぶ前の窓のこともある。メニューや外部操作で移る先を出す窓。
    private(set) var activeWindow: BrowserWindowSlot?
    /// 新しいプロファイルの名前を尋ねている窓。
    var creatingIn: BrowserWindowSlot?
    /// 利用者に見せる失敗。
    var failure: String?

    @ObservationIgnored let contentBlocker: ContentBlocker?
    /// ダウンロードの一覧。プロファイルを切り替えても続く。
    let downloads: Downloads
    /// 開いているプロファイルのタブ管理。窓に出ているものと、窓がひとつもなくなったときの `current`。
    private var stores: [String: TabStore]
    /// 起動したとき、続けて窓を開いて戻すプロファイル。
    @ObservationIgnored private var pendingWindows: [String] = []
    /// 持ち物の根元。使い捨ての実体では `nil` で、何も保存せず、作った名前はこの実体の中にだけ持つ。
    @ObservationIgnored private let directory: URL?
    /// サイトデータを保存するか。テストでは保存する置き場を試しても、WebKit の置き場は作らない。
    @ObservationIgnored private let keepsSiteData: Bool
    @ObservationIgnored private var registered: [ProfileRegistry.Entry]
    @ObservationIgnored private var temporaryNames: [String] = []
    /// 一度開いたプロファイルの持ち物。離れても捨てずに、戻ったときに同じものを使う。
    /// 同じファイルを二つのストアが書き合わないためと、使い捨ての実体でも閲覧状態を戻せるようにするため。
    @ObservationIgnored private var opened: [String: ProfileData] = [:]
    /// 終了の途中。終えるときに窓が閉じても、次の起動で戻す窓の一覧から外さない。
    @ObservationIgnored private var isQuitting = false

    /// `directory` は持ち物の根元（`default` の持ち物と一覧をここに、ほかは `profiles/<名前>/` に置く）。
    init(directory: URL?, contentBlocker: ContentBlocker?, keepsSiteData: Bool = true) {
        self.directory = directory
        self.contentBlocker = contentBlocker
        self.keepsSiteData = keepsSiteData
        let downloads = Downloads.forInstance(persistent: directory != nil && keepsSiteData, instance: BrowserInstance.name)
        self.downloads = downloads
        let registry = directory.flatMap { try? ProfileRegistry.load(from: ProfileRegistry.fileURL(in: $0)) } ?? ProfileRegistry()
        let names = [BrowserProfile.defaultName] + registry.profiles.map(\.name)
        let start = registry.lastOpened.flatMap { names.contains($0) ? $0 : nil } ?? BrowserProfile.defaultName
        registered = registry.profiles
        self.names = names
        current = start
        let data = ProfileData(
            name: start, entry: registry.profiles.first { $0.name == start }, directory: directory, keepsSiteData: keepsSiteData)
        opened = [start: data]
        let store = Self.makeStore(with: data, contentBlocker: contentBlocker, downloads: downloads)
        self.store = store
        stores = [start: store]
        // 最初の窓に最後に開いていたプロファイルを出し、ほかは続けて開く窓に出す。
        var pending = [start]
        for name in registry.lastWindows ?? [] where names.contains(name) && !pending.contains(name) {
            pending.append(name)
        }
        pendingWindows = pending
    }

    /// テスト用。渡したタブ管理を `default` として持つ、使い捨ての実体のモデル。
    init(store: TabStore) {
        directory = nil
        keepsSiteData = false
        contentBlocker = store.contentBlocker
        downloads = store.downloads
        registered = []
        names = [BrowserProfile.defaultName]
        current = BrowserProfile.defaultName
        self.store = store
        stores = [BrowserProfile.defaultName: store]
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

    /// そのプロファイルへ移る。窓を省くと、最後に前へ出た窓で移る。移ったら `true`、もうそこにいたら `false`。
    ///
    /// ほかの窓に出ていれば、その窓を前に出すだけにする。そうでなければ、窓に出ていたプロファイルの閲覧状態を書き出して
    /// ページをすべて閉じ、移る先のタブを閲覧状態から戻す。離れたプロファイルのページは生かしておかない
    /// （切り替えは頻繁ではないので、戻ったときに選んでいたページだけ読み込み直す）。
    @discardableResult
    func switchTo(_ name: String, in window: BrowserWindowSlot? = nil) throws -> Bool {
        guard names.contains(name) else { throw ProfileError("「\(name)」というプロファイルはない") }
        let target = window ?? activeWindow
        if let shown = windows.first(where: { $0.profile == name }) {
            guard shown !== target else { return false }
            shown.window?.makeKeyAndOrderFront(nil)
            activate(shown)
            return true
        }
        guard let target else {
            // 窓がない（テストや、窓をすべて閉じたあと）。窓のない今のプロファイルを入れ替える。
            guard name != current else { return false }
            let leaving = current
            show(name)
            close(leaving)
            remember()
            return true
        }
        let leaving = target.profile
        show(name)
        target.profile = name
        activeWindow = target
        if let leaving { close(leaving) }
        closeProfilesWithoutWindow()
        remember()
        return true
    }

    /// メニューやキー、プロファイルを選ぶ窓から。失敗はアラートで見せる。
    func open(_ name: String, in window: BrowserWindowSlot? = nil) {
        do {
            try switchTo(name, in: window)
        } catch {
            failure = String(describing: error)
        }
    }

    /// 新しいプロファイルの名前を、その窓で尋ねる。
    func beginCreating(in window: BrowserWindowSlot? = nil) {
        creatingIn = window ?? activeWindow
    }

    /// 名前を尋ねたシートから。失敗はアラートで見せる。
    func createAndOpen(_ rawName: String, in window: BrowserWindowSlot? = nil) {
        do {
            try switchTo(try create(rawName), in: window)
        } catch {
            failure = String(describing: error)
        }
    }

    /// 終了直前に呼ぶ。閲覧状態と履歴は変化から少し遅れて書き出すので、最後の変化を取りこぼさないよう書く。
    func saveBeforeQuit() {
        isQuitting = true
        for store in stores.values {
            store.saveSession()
        }
        for data in opened.values {
            data.history.saveNow()
        }
        remember()
    }

    // MARK: 窓

    /// 窓が出たとき。起動して戻す窓がまだ残っていれば `true` を返すので、続けて窓を開くこと。
    ///
    /// 起動したときは覚えていたプロファイルを順に出す。窓をすべて閉じたあとに開いた窓には、閉じる前のプロファイルを戻す。
    /// それ以外（⌘N）はプロファイルを選ぶ前の窓になる。
    func attach(_ window: BrowserWindowSlot) -> Bool {
        guard !windows.contains(where: { $0 === window }) else { return false }
        windows.append(window)
        if !pendingWindows.isEmpty {
            let name = pendingWindows.removeFirst()
            if stores[name] == nil {
                stores[name] = makeStore(for: name)
            }
            window.profile = name
        } else if !isShown(current) {
            window.profile = current
        }
        if activeWindow == nil {
            activeWindow = window
        }
        guard pendingWindows.isEmpty else { return true }
        remember()
        return false
    }

    /// 窓が閉じたとき。ほかにプロファイルを出している窓があれば、閉じた窓のプロファイルのページを閉じる。
    /// 最後の窓なら、タブ管理はそのまま残す（Dock から窓を開き直したときに戻す）。
    func detach(_ window: BrowserWindowSlot) {
        guard windows.contains(where: { $0 === window }) else { return }
        windows.removeAll { $0 === window }
        if creatingIn === window { creatingIn = nil }
        if activeWindow === window {
            activeWindow = windows.last { $0.profile != nil } ?? windows.last
        }
        // 終えるときに窓が閉じても、次の起動で戻せるよう何も変えない（書き出しは saveBeforeQuit で済んでいる）。
        guard !isQuitting, let name = window.profile,
              let next = activeWindow?.profile ?? windows.last(where: { $0.profile != nil })?.profile
        else { return }
        if name == current { show(next) }
        close(name)
        remember()
    }

    /// 窓が前に出たとき。メニューと外部操作は、この窓のプロファイルを相手にする。
    func activate(_ window: BrowserWindowSlot) {
        guard windows.contains(where: { $0 === window }) else { return }
        activeWindow = window
        if let name = window.profile, name != current { show(name) }
    }

    /// その窓に出すタブ管理。プロファイルを選ぶ前の窓では `nil`。
    func store(in window: BrowserWindowSlot) -> TabStore? {
        window.profile.flatMap { stores[$0] }
    }

    func isShown(_ name: String) -> Bool {
        windows.contains { $0.profile == name }
    }

    /// アラートを出す窓か。
    func isActive(_ window: BrowserWindowSlot) -> Bool {
        activeWindow === window
    }

    /// `current` を出している AppKit の窓。
    var currentWindow: NSWindow? {
        windows.first { $0.profile == current }?.window
    }

    // MARK: 内部

    /// そのプロファイルを今のものにする。タブ管理がなければ閲覧状態から作る。
    private func show(_ name: String) {
        let next = stores[name] ?? makeStore(for: name)
        stores[name] = next
        current = name
        store = next
    }

    /// プロファイルのページを閉じる。今のプロファイルは閉じない（`store` が閉じたものを指さないため）。
    private func close(_ name: String) {
        guard name != current, let leaving = stores.removeValue(forKey: name) else { return }
        leaving.shutDown()
        // 小窓は開いたプロファイルのサイトデータを使っているので、残すと別のプロファイルの中に紛れる。
        PopupWindows.close(openedBy: leaving)
    }

    /// 窓に出ていないプロファイルのページを閉じる。プロファイルを出している窓がひとつもなければ何もしない。
    private func closeProfilesWithoutWindow() {
        let shown = Set(windows.compactMap(\.profile))
        guard !shown.isEmpty else { return }
        for name in Array(stores.keys) where !shown.contains(name) && !pendingWindows.contains(name) {
            close(name)
        }
    }

    private func makeStore(for name: String) -> TabStore {
        let data = opened[name] ?? ProfileData(
            name: name, entry: registered.first { $0.name == name }, directory: directory, keepsSiteData: keepsSiteData)
        opened[name] = data
        return Self.makeStore(with: data, contentBlocker: contentBlocker, downloads: downloads)
    }

    private static func makeStore(with data: ProfileData, contentBlocker: ContentBlocker?, downloads: Downloads) -> TabStore {
        TabStore(
            factory: PageFactory(dataStore: data.dataStore, contentBlocker: contentBlocker, downloads: downloads),
            bookmarks: data.bookmarks,
            history: data.history,
            favicons: data.favicons,
            session: data.session
        )
    }

    /// 次の起動で同じプロファイルの窓を開くために覚える。今のプロファイルの窓を最初に開く。
    /// 窓が一枚きりなら、窓の一覧は書かない。
    private func remember() {
        guard let registryURL else { return }
        let lastOpened = current == BrowserProfile.defaultName ? nil : current
        let shown = windows.compactMap(\.profile)
        let lastWindows = shown.count > 1 ? shown : nil
        do {
            var registry = try ProfileRegistry.load(from: registryURL)
            guard registry.lastOpened != lastOpened || registry.lastWindows != lastWindows else { return }
            registry.lastOpened = lastOpened
            registry.lastWindows = lastWindows
            try registry.save(to: registryURL)
        } catch {
            NSLog("開いていたプロファイルを覚えられませんでした: \(error)")
        }
    }
}

/// 本体の窓一枚。どのプロファイルを出しているかと、その AppKit の窓。
///
/// ⌘N で開いてプロファイルを選ぶ前の窓は `profile` が `nil`。
@MainActor
@Observable
final class BrowserWindowSlot {
    fileprivate(set) var profile: String? {
        didSet { rememberFrame() }
    }
    /// 窓に置かれるまでは `nil`。テストでは窓を持たない。
    @ObservationIgnored weak var window: NSWindow? {
        didSet { rememberFrame() }
    }

    init() {}

    private func rememberFrame() {
        guard let window, let profile else { return }
        WindowFrameMemory.remember(window, as: profile)
    }
}

/// プロファイル一つぶんの持ち物。
@MainActor
final class ProfileData {
    let dataStore: WKWebsiteDataStore
    let bookmarks: BookmarkStore
    let history: HistoryStore
    let favicons: FaviconStore
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
        favicons = FaviconStore(directory: directory?.appending(path: "favicons"))
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

