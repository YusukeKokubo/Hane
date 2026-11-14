import ControlWire
import Foundation
import Observation
import WebKit

/// アプリ全体の状態。プロファイルの一覧と、開いている本体の窓を持つ。
///
/// プロファイルは窓一枚に一つずつ出し、その窓（`BrowserWindowSlot`）がプロファイルのタブ管理を持つ。
/// 一度出した窓は閉じるまで同じプロファイルのままで、ほかのプロファイルを開くときは別の窓に出す。
/// 同じプロファイルを二枚の窓には出さない（閲覧状態を書き合わないため）。
/// メニュー・外部操作は、最後に前へ出たプロファイルの窓（`activeWindow`）のタブ管理（`store`）を見る。
/// 窓を閉じるとそのタブ管理も閉じるので、掴んでおかずに使うたびに `store` を読むこと。
@MainActor
@Observable
final class BrowserModel {
    /// メニューに並べる順。`default` が先頭で、続いて登録した順（使い捨ての実体では作った順）。
    private(set) var names: [String]
    /// 開いている本体の窓。開いた順。
    private(set) var windows: [BrowserWindowSlot] = []
    /// 最後に前へ出たプロファイルの窓。メニューや外部操作の相手。プロファイルを出している窓がなければ `nil`。
    private(set) var activeWindow: BrowserWindowSlot?
    /// 最後に前へ出た窓。プロファイルを選ぶ前の窓のこともある。アラートを出す窓と、プロファイルを割り当てる空の窓を決める。
    private(set) var focusedWindow: BrowserWindowSlot?
    /// 新しいプロファイルの名前を尋ねている窓。
    var creatingIn: BrowserWindowSlot?
    /// 利用者に見せる失敗。
    var failure: String?

    @ObservationIgnored let contentBlocker: ContentBlocker?
    /// ダウンロードの一覧。プロファイルによらずアプリ全体で一つ。
    let downloads: Downloads
    /// 1Password で入れる場所として教わったもの。プロファイルによらずアプリ全体で一つ。
    @ObservationIgnored let loginFields: LoginFieldStore
    /// 窓一枚ぶんの AppKit の窓を作って前に出す。アプリでは `MainWindow.open`。テストでは AppKit の窓を作らない。
    @ObservationIgnored var makeWindow: @MainActor (BrowserWindowSlot) -> Void = { _ in }
    /// 起動したときに窓を開いて戻すプロファイル。`restoreWindows` で使い切る。
    @ObservationIgnored private var restoring: [String] = []
    /// 起動したときの窓をまだ開いていない。外部操作は起こしてすぐ命令を送るので、これを見て窓が出るのを待つ。
    private(set) var isLaunching = true
    /// 最後に前へ出ていたプロファイル。窓をすべて閉じたあとに開いた窓に戻すものと、次の起動で最初に開くもの。
    @ObservationIgnored private var lastProfile: String
    /// 持ち物の根元。使い捨ての実体では `nil` で、何も保存せず、作った名前はこの実体の中にだけ持つ。
    @ObservationIgnored private let directory: URL?
    /// サイトデータを保存するか。テストでは保存する置き場を試しても、WebKit の置き場は作らない。
    @ObservationIgnored private let keepsSiteData: Bool
    /// ページの console 出力と例外を記録するか。`hanectl logs` のためだけの仕掛けなので、開発用の実体だけが付ける。
    @ObservationIgnored private let capturesConsole: Bool
    @ObservationIgnored private var registered: [ProfileRegistry.Entry]
    @ObservationIgnored private var temporaryNames: [String] = []
    /// 一度開いたプロファイルの持ち物。窓を閉じても捨てずに、また開いたときに同じものを使う。
    /// 同じファイルを二つのストアが書き合わないためと、使い捨ての実体でも閲覧状態を戻せるようにするため。
    @ObservationIgnored private var opened: [String: ProfileData] = [:]
    /// 終了の途中。終えるときに窓が閉じても、次の起動で戻す窓の一覧から外さない。
    @ObservationIgnored private var isQuitting = false

    /// `directory` は持ち物の根元（`default` の持ち物と一覧をここに、ほかは `profiles/<名前>/` に置く）。
    init(directory: URL?, contentBlocker: ContentBlocker?, keepsSiteData: Bool = true, capturesConsole: Bool = true) {
        self.directory = directory
        self.capturesConsole = capturesConsole
        self.contentBlocker = contentBlocker
        self.keepsSiteData = keepsSiteData
        downloads = Downloads.forInstance(persistent: directory != nil && keepsSiteData, instance: BrowserInstance.name)
        loginFields = LoginFieldStore(fileURL: keepsSiteData ? directory?.appending(path: "login-fields.json") : nil)
        let registry = directory.flatMap { try? ProfileRegistry.load(from: ProfileRegistry.fileURL(in: $0)) } ?? ProfileRegistry()
        let names = [BrowserProfile.defaultName] + registry.profiles.map(\.name)
        let start = registry.lastOpened.flatMap { names.contains($0) ? $0 : nil } ?? BrowserProfile.defaultName
        registered = registry.profiles
        self.names = names
        lastProfile = start
        // 最初の窓に最後に開いていたプロファイルを出し、ほかは続けて開く窓に出す。
        var restoring = [start]
        for name in registry.lastWindows ?? [] where names.contains(name) && !restoring.contains(name) {
            restoring.append(name)
        }
        self.restoring = restoring
    }

    /// テスト用。AppKit の窓を持たない窓一枚が、渡したタブ管理を `default` として出して前にいる、使い捨ての実体のモデル。
    init(store: TabStore) {
        directory = nil
        keepsSiteData = false
        capturesConsole = true
        contentBlocker = store.contentBlocker
        downloads = store.downloads
        loginFields = store.passwordFill.places
        registered = []
        names = [BrowserProfile.defaultName]
        lastProfile = BrowserProfile.defaultName
        isLaunching = false
        let window = BrowserWindowSlot()
        window.show(BrowserProfile.defaultName, store)
        windows = [window]
        activeWindow = window
        focusedWindow = window
    }

    /// 普段使いの実体は登録した一覧を使い、使い捨ての実体は見せない（そこから持ち主のデータに触れないため）。
    static func forInstance(contentBlocker: ContentBlocker?) -> BrowserModel {
        BrowserModel(
            directory: BrowserInstance.dataDirectory, contentBlocker: contentBlocker, capturesConsole: BrowserInstance.name != nil)
    }

    var isPersistent: Bool { directory != nil }

    /// 最後に前へ出たプロファイルの窓のプロファイル。窓がなければ `nil`。
    var current: String? { activeWindow?.profile }

    /// 最後に前へ出たプロファイルの窓のタブ管理。窓がなければ `nil`。
    var store: TabStore? { activeWindow?.store }

    /// 最後に前へ出たプロファイルの窓の AppKit の窓。
    var currentWindow: NSWindow? { activeWindow?.window }

    private var registryURL: URL? { directory.map(ProfileRegistry.fileURL(in:)) }

    static func title(for name: String) -> String {
        name == BrowserProfile.defaultName ? "標準" : name
    }

    // MARK: 作る・開く

    /// プロファイルを作って一覧に足す。開くのは別（`openProfile`）。
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

    /// プロファイルを開いた結果。
    enum Opening: Equatable {
        /// もう前に出ている窓に出ていた。
        case alreadyHere
        /// ほかの窓に出ていたので、その窓を前に出した。
        case broughtToFront
        /// プロファイルを選ぶ前の窓に出した。
        case shownInEmptyWindow
        /// 新しい窓で開いた。
        case openedInNewWindow
    }

    /// そのプロファイルを開く。窓に出ていればその窓を前に出し、出ていなければ新しい窓で開く。今の窓のタブは閉じない。
    ///
    /// プロファイルを選ぶ前の窓を渡すと（省くと、最後に前へ出た窓がそれなら）、新しい窓ではなくその窓に出す。
    @discardableResult
    func openProfile(_ name: String, in window: BrowserWindowSlot? = nil) throws -> Opening {
        guard names.contains(name) else { throw ProfileError("「\(name)」というプロファイルはない") }
        if let shown = windows.first(where: { $0.profile == name }) {
            let wasActive = shown === activeWindow
            shown.window?.makeKeyAndOrderFront(nil)
            activate(shown)
            return wasActive ? .alreadyHere : .broughtToFront
        }
        if let empty = window ?? focusedWindow, empty.profile == nil, windows.contains(where: { $0 === empty }) {
            empty.show(name, makeStore(for: name))
            activate(empty)
            remember()
            return .shownInEmptyWindow
        }
        let slot = BrowserWindowSlot()
        slot.show(name, makeStore(for: name))
        add(slot)
        // 命令やキーが、続けてこの窓を相手にできるように。裏にいると窓が前に出た知らせが来ないため。
        activeWindow = slot
        lastProfile = name
        remember()
        return .openedInNewWindow
    }

    /// プロファイルを選ぶ前の窓を開く（⌘N）。
    @discardableResult
    func openEmptyWindow() -> BrowserWindowSlot {
        let slot = BrowserWindowSlot()
        add(slot)
        return slot
    }

    /// 起動したときに一度だけ呼ぶ。覚えていたプロファイルの窓を順に開き、最後に前にあったものを前に出す。
    func restoreWindows() {
        let names = restoring
        restoring = []
        isLaunching = false
        var first: BrowserWindowSlot?
        for name in names where !isShown(name) {
            let slot = BrowserWindowSlot()
            slot.show(name, makeStore(for: name))
            add(slot)
            first = first ?? slot
        }
        if let first {
            first.window?.makeKeyAndOrderFront(nil)
            activate(first)
        }
        remember()
    }

    /// Dock のアイコンなどで開き直したとき。窓がひとつもなければ、最後に前へ出ていたプロファイルの窓を開く。
    func reopen() {
        guard windows.isEmpty else { return }
        openLastProfile()
    }

    /// メニューやキー、プロファイルを選ぶ窓から。失敗はアラートで見せる。
    func open(_ name: String, in window: BrowserWindowSlot? = nil) {
        do {
            try openProfile(name, in: window)
        } catch {
            failure = String(describing: error)
        }
    }

    /// 窓をすべて閉じたあとに、最後に前へ出ていたプロファイルを開き直す（外から渡されたリンクのため）。
    func openLastProfile() {
        open(lastProfile)
    }

    /// 新しいプロファイルの名前を、その窓で尋ねる。
    func beginCreating(in window: BrowserWindowSlot? = nil) {
        creatingIn = window ?? focusedWindow
    }

    /// 名前を尋ねたシートから。失敗はアラートで見せる。
    func createAndOpen(_ rawName: String, in window: BrowserWindowSlot? = nil) {
        do {
            try openProfile(try create(rawName), in: window)
        } catch {
            failure = String(describing: error)
        }
    }

    /// 終了直前に呼ぶ。閲覧状態と履歴は変化から少し遅れて書き出すので、最後の変化を取りこぼさないよう書く。
    func saveBeforeQuit() {
        isQuitting = true
        for window in windows {
            window.store?.saveSession()
        }
        for data in opened.values {
            data.history.saveNow()
        }
        remember()
    }

    // MARK: 窓

    /// 窓を一覧に足して、AppKit の窓を作る。
    private func add(_ window: BrowserWindowSlot) {
        windows.append(window)
        // 裏にいると窓が前に出た知らせが来ないので、アラートを出す窓とプロファイルを割り当てる空の窓をここで移す。
        focusedWindow = window
        makeWindow(window)
    }

    /// 窓が閉じたとき。最後の一枚でも、閉じた窓のプロファイルのタブ管理を閉じる。
    /// 閲覧状態は書き出してあるので、窓を開き直せば戻る。
    func detach(_ window: BrowserWindowSlot) {
        guard windows.contains(where: { $0 === window }) else { return }
        windows.removeAll { $0 === window }
        if creatingIn === window { creatingIn = nil }
        if focusedWindow === window { focusedWindow = windows.last }
        if activeWindow === window {
            activeWindow = windows.last { $0.profile != nil }
        }
        // 終えるときに窓が閉じても、次の起動で戻せるよう何も変えない（書き出しは saveBeforeQuit で済んでいる）。
        guard !isQuitting, let name = window.profile, let store = window.store else { return }
        lastProfile = activeWindow?.profile ?? name
        store.shutDown()
        // 小窓は開いたプロファイルのサイトデータを使っているので、残すと別のプロファイルの中に紛れる。
        PopupWindows.close(openedBy: store)
        remember()
    }

    /// 窓が前に出たとき。プロファイルを出している窓なら、メニューと外部操作はこの窓のタブ管理を相手にする。
    func activate(_ window: BrowserWindowSlot) {
        guard windows.contains(where: { $0 === window }) else { return }
        focusedWindow = window
        guard let name = window.profile else { return }
        activeWindow = window
        lastProfile = name
    }

    func isShown(_ name: String) -> Bool {
        windows.contains { $0.profile == name }
    }

    /// そのプロファイルを出している窓。
    func window(showing name: String) -> BrowserWindowSlot? {
        windows.first { $0.profile == name }
    }

    /// アラートを出す窓か。
    func isActive(_ window: BrowserWindowSlot) -> Bool {
        (focusedWindow ?? activeWindow) === window
    }

    // MARK: 内部

    private func makeStore(for name: String) -> TabStore {
        let data = opened[name] ?? ProfileData(
            name: name, entry: registered.first { $0.name == name }, directory: directory, keepsSiteData: keepsSiteData)
        opened[name] = data
        return TabStore(
            factory: PageFactory(
                dataStore: data.dataStore, contentBlocker: contentBlocker, downloads: downloads, capturesConsole: capturesConsole),
            bookmarks: data.bookmarks,
            history: data.history,
            favicons: data.favicons,
            session: data.session,
            loginFields: loginFields
        )
    }

    /// 次の起動で同じプロファイルの窓を開くために覚える。最後に前へ出ていたプロファイルの窓を最初に開く。
    /// 窓が一枚きりなら、窓の一覧は書かない。
    private func remember() {
        guard let registryURL else { return }
        let first = activeWindow?.profile ?? lastProfile
        let lastOpened = first == BrowserProfile.defaultName ? nil : first
        let shown = windows.compactMap(\.profile)
        let lastWindows = shown.count > 1 ? shown : nil
        do {
            var registry = try ProfileRegistry.load(from: registryURL)
            guard registry.lastOpened != lastOpened || registry.lastWindows != lastWindows else { return }
            registry.lastOpened = lastOpened
            registry.lastWindows = lastWindows
            try registry.save(to: registryURL)
        } catch {
            AppLog.logger.error("開いていたプロファイルを覚えられませんでした: \(String(describing: error), privacy: .public)")
        }
    }
}

/// 本体の窓一枚。出しているプロファイルとそのタブ管理、AppKit の窓を持つ。
///
/// ⌘N で開いてプロファイルを選ぶ前の窓は、`profile` も `store` も `nil`。一度出したら、窓を閉じるまで変わらない。
@MainActor
@Observable
final class BrowserWindowSlot {
    private(set) var profile: String?
    private(set) var store: TabStore?
    /// 窓を作るまでは `nil`。テストでは窓を持たない。
    @ObservationIgnored weak var window: NSWindow? {
        didSet { rememberFrame() }
    }

    init() {}

    /// プロファイルを出す。BrowserModel だけが呼ぶ。
    fileprivate func show(_ name: String, _ store: TabStore) {
        guard profile == nil else {
            assertionFailure("窓の中でプロファイルを入れ替えない")
            return
        }
        profile = name
        self.store = store
        rememberFrame()
    }

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

