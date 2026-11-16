import AppKit
import ControlWire
import Foundation

/// 外部からの操作要求を、タブとページへの操作に置き換える。
///
/// 命令の名前と引数を読んで、受け持ちへ渡す。受け持ちは、ページの中を読む・操作する `PageScripting`、
/// 通信の記録の `PageRequests`、ページへの本物の入力の `PageInput`、窓まわりへの入力の `WindowInput`、
/// 窓の部品の `WindowElements`、状態を文字にする `StateText`。依り方は振り分けから各層への一方向で、
/// 層どうしでは `PageScripting` がいちばん下にいる。
///
/// 命令の一覧と書式は `ControlHelp` の文面が正本。
@MainActor
final class ControlService {
    private let model: BrowserModel
    private let settings: SettingsStore
    private let state: StateText
    private let pages: PageScripting
    private let input: PageInput
    private let windows: WindowInput
    /// `ui-snapshot` で振った番号と、窓まわりの部品の対応。
    private let windowElements: WindowElements
    /// 操作用ソケットの待ち受け。`quit` で止める。
    private var listener: ControlServer.Listener?

    /// `hanectl` は 120 秒答えがないと落ちるので、条件を待つ上限はそれより短くする。
    private static let waitTimeoutLimit: Double = 100

    init(model: BrowserModel, settings: SettingsStore = SettingsStore()) {
        self.model = model
        self.settings = settings
        let state = StateText(model: model)
        self.state = state
        pages = PageScripting(
            describe: { state.tab($0) },
            sheetIsShown: { [weak model] in
                if let sheet = model?.currentWindow?.attachedSheet, sheet.isVisible { return true }
                return false
            })
        input = PageInput(pages: pages) { [weak model] in
            guard let model else { return nil }
            return try Self.store(of: model).selectedID
        }
        windows = WindowInput(model: model)
        windowElements = WindowElements { [weak model] in model?.currentWindow }
    }

    /// テスト用。渡したタブ管理を持つ使い捨ての実体として振る舞う。
    convenience init(store: TabStore) {
        self.init(model: BrowserModel(store: store))
    }

    /// 今のプロファイル（最後に前へ出たプロファイルの窓）のタブ管理。窓を移ったり閉じたりすると入れ替わるので、掴んでおかずに毎回読む。
    /// プロファイルを出している窓がひとつもなければ断る。
    private var store: TabStore {
        get throws { try Self.store(of: model) }
    }

    private static func store(of model: BrowserModel) throws -> TabStore {
        guard let store = model.store else {
            throw ControlError("プロファイルを出している窓がない。profile-open <名前> で開くこと。")
        }
        return store
    }

    func start() {
        do {
            listener = try ControlServer.start { [weak self] request in
                await self?.respond(to: request) ?? ControlResponse(ok: false, output: "アプリが終了中")
            }
        } catch {
            AppLog.logger.error("操作用ソケットを開けませんでした: \(String(describing: error), privacy: .public)")
        }
    }

    func respond(to request: ControlRequest) async -> ControlResponse {
        do {
            return ControlResponse(ok: true, output: try await run(request.args))
        } catch let error as ControlError {
            return ControlResponse(ok: false, output: error.message)
        } catch {
            return ControlResponse(ok: false, output: ControlError.describe(error))
        }
    }

    // MARK: 命令の振り分け

    /// どの命令にも付けられる引数。
    private struct Options {
        let tabNumber: Int?
        let limit: Int?
        let fullPage: Bool
        let clear: Bool
    }

    private func run(_ rawArgs: [String]) async throws -> String {
        var args = rawArgs
        let options = Options(
            tabNumber: try takeOption("--tab", from: &args).map { try integer($0, "--tab") },
            limit: try takeOption("--limit", from: &args).map { try integer($0, "--limit") },
            fullPage: takeFlag("--full", from: &args),
            clear: takeFlag("--clear", from: &args))
        guard let command = args.first else { return ControlHelp.text }
        args.removeFirst()

        // 操作用ソケットはアプリの init で開くが、起動したときの窓は起動を終えたとき（applicationDidFinishLaunching）に開く。
        // その間に hanectl が起こしてすぐ送った命令が届くことがあるので、窓を開き終えるまで待つ。
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while model.isLaunching, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        if ["help", "--help", "-h"].contains(command) { return ControlHelp.text }
        if let output = try await tabCommand(command, &args, options) { return output }
        if let output = try await pageCommand(command, &args, options) { return output }
        if let output = try await windowCommand(command, &args, options) { return output }
        if let output = try await bookmarkCommand(command, &args, options) { return output }
        if let output = try groupCommand(command, &args, options) { return output }
        if let output = try await siteCommand(command, &args, options) { return output }
        if let output = try await profileCommand(command, &args) { return output }
        if let output = try await appCommand(command, &args, options) { return output }
        throw ControlError("未知の命令: \(command)。`hanectl help` で一覧を見ること。")
    }

    /// タブの一覧と、タブを開く・移る・閉じる・眠らせる。
    private func tabCommand(_ command: String, _ args: inout [String], _ options: Options) async throws -> String? {
        switch command {
        case "tabs":
            return try state.tabs(of: store)

        case "new":
            if args.isEmpty {
                return state.tab(try store.newTab())
            }
            let tab = try store.open(URLRequest(url: try url(from: args)))
            return try await pages.settled(tab)

        case "select":
            let tab = try tab(numbered: try integer(try argument(args, 0, "タブ番号"), "タブ番号"))
            try store.selectedID = tab.id
            return state.tab(tab)

        case "close":
            let number = try args.first.map { try integer($0, "タブ番号") } ?? options.tabNumber
            let tab = try tab(numbered: number)
            // ブックマークのページは閉じてもウインドウが残るので、最後の1枚でも閉じてよい。
            guard try store.everyTab.count > 1 || store.bookmarkID(of: tab) != nil else {
                throw ControlError("最後の1枚は閉じられない（ウインドウが閉じてアプリが終了するため）。")
            }
            try store.close(tab.id)
            return try "closed tab \(tab.number)\n" + state.tabs(of: store)

        case "open":
            let tab = try target(options)
            tab.load(URLRequest(url: try url(from: args)))
            return try await pages.settled(tab)

        case "back":
            let tab = try target(options)
            guard tab.canGoBack else { throw ControlError("これより前の履歴はない。") }
            tab.goBack()
            return try await pages.settled(tab)

        case "forward":
            let tab = try target(options)
            guard tab.canGoForward else { throw ControlError("これより先の履歴はない。") }
            tab.goForward()
            return try await pages.settled(tab)

        case "reload":
            let tab = try target(options)
            tab.reload()
            return try await pages.settled(tab)

        case "sleep":
            let number = try args.first.map { try integer($0, "タブ番号") } ?? options.tabNumber
            let tab = try tab(numbered: number)
            guard try tab.id != store.selectedID else { throw ControlError("画面に出ているタブは眠らせられない。先に別のタブを選ぶこと。") }
            guard tab.sleep() else { throw ControlError("このタブはページを持っていない（もう眠っているか、まだ何も開いていない）。") }
            return try state.tabs(of: store)

        case "history":
            return try state.history(of: store, limit: options.limit ?? 30)

        default:
            return nil
        }
    }

    /// ページの中を読む・操作する、本物の入力を渡す、ページの記録を見る。
    private func pageCommand(_ command: String, _ args: inout [String], _ options: Options) async throws -> String? {
        switch command {
        case "wait":
            let text = try takeOption("--text", from: &args)
            let selector = try takeOption("--selector", from: &args)
            let script = try takeOption("--js", from: &args)
            let gone = takeFlag("--gone", from: &args)
            let timeout = try takeOption("--timeout", from: &args).map { text in
                guard let value = Double(text), (0.1...Self.waitTimeoutLimit).contains(value) else {
                    throw ControlError("--timeout は 0.1〜\(Int(Self.waitTimeoutLimit)) 秒の数で指定すること: \(text)")
                }
                return value
            } ?? 10
            let path = try takeOption("--frame", from: &args).map(PageScripting.framePath)
            if let extra = args.first { throw ControlError("wait に余分な引数がある: \(extra)") }
            let conditions = PageScripting.WaitConditions(text: text, selector: selector, script: script, gone: gone)
            guard !conditions.isEmpty else {
                if gone || path != nil { throw ControlError("--gone と --frame には、--text、--selector、--js のどれかが要る。") }
                return try await pages.settled(try target(options))
            }
            return try await pages.waitFor(conditions, in: path, timeout: timeout, on: try target(options))

        case "snapshot":
            return try await pages.snapshot(of: try target(options), limit: options.limit ?? 300)

        case "text":
            let tab = try target(options)
            let path = try takeOption("--frame", from: &args).map(PageScripting.framePath)
            return try await pages.text(of: tab, in: path, limit: options.limit ?? 50_000)

        case "click":
            let ref = try integer(try argument(args, 0, "要素の番号"), "要素の番号")
            return try await pages.act("click", ref: ref, text: "", on: try target(options))

        case "fill":
            let ref = try integer(try argument(args, 0, "要素の番号"), "要素の番号")
            guard args.count >= 2 else { throw ControlError("入力する文字列がない。例: fill 3 \"hello\"") }
            return try await pages.act("fill", ref: ref, text: args.dropFirst().joined(separator: " "), on: try target(options))

        case "press":
            let key = try argument(args, 0, "キー名")
            let ref = try args.count >= 2 ? integer(args[1], "要素の番号") : 0
            return try await pages.act("press", ref: ref, text: key, on: try target(options))

        case "eval":
            let path = try takeOption("--frame", from: &args).map(PageScripting.framePath)
            guard !args.isEmpty else { throw ControlError("JavaScriptがない。例: eval \"document.title\"") }
            let tab = try target(options)
            return try await pages.eval(args.joined(separator: " "), in: path, on: tab)

        case "page-click":
            let right = takeFlag("--right", from: &args)
            let modifiers = try takeOption("--with", from: &args).map { try KeySpec.modifiers(from: $0.lowercased().split(separator: "+").map(String.init)) } ?? []
            return try await input.click(try argument(args, 0, "要素の番号か位置"), right: right, modifiers: modifiers, on: try target(options))

        case "page-hover":
            return try await input.hover(try argument(args, 0, "要素の番号か位置"), on: try target(options))

        case "page-key":
            guard !args.isEmpty else { throw ControlError("キーがない。例: page-key j、page-key g g、page-key shift+g") }
            try await input.press(args, on: try target(options))
            return try "sent \(args.joined(separator: " "))\n" + state.tabs(of: store)

        case "screenshot":
            return try await input.screenshot(of: try target(options), to: args.first, fullPage: options.fullPage)

        case "logs":
            let tab = try target(options)
            let output = state.logs(of: tab, limit: options.limit ?? 50)
            if options.clear { tab.log.clear() }
            return output

        case "requests":
            let json = takeFlag("--json", from: &args)
            let filter = PageRequests.Filter(
                url: try takeOption("--url", from: &args)?.lowercased(),
                types: try takeOption("--type", from: &args).map { Set($0.lowercased().split(separator: ",").map(String.init)) })
            let tab = try target(options)
            let frames = try await PageRequests(pages: pages).read(of: tab)
            return json
                ? try PageRequests.json(frames, tab: tab, filter: filter, limit: options.limit ?? 200)
                : state.tab(tab) + "\n" + PageRequests.text(frames, filter: filter, limit: options.limit ?? 200)

        default:
            return nil
        }
    }

    /// 窓まわり（ページの外）を見る・触る。
    private func windowCommand(_ command: String, _ args: inout [String], _ options: Options) async throws -> String? {
        switch command {
        case "ui":
            return state.ui()

        case "ui-snapshot":
            return try await windowElements.snapshot()

        case "ui-click":
            let result = try windowElements.click(try await windowElements.resolve(try argument(args, 0, "部品の番号か名前")))
            return await afterUIAction(result)

        case "ui-hover":
            let result = try windowElements.hover(try await windowElements.resolve(try argument(args, 0, "部品の番号か名前")))
            return await afterUIAction(result)

        case "ui-menu":
            let menu = try await windowElements.menu(try await windowElements.resolve(try argument(args, 0, "部品の番号か名前")))
            guard args.count > 1 else {
                return "menu of \(menu.label):\n" + menu.items.enumerated().map { index, item in
                    "  [\(index + 1)] " + (item === menu.selected ? "* " : "") + item.title
                        + (item.isEnabled ? "" : " (disabled)") + (item.hasSubmenu ? " ▸" : "")
                }.joined(separator: "\n")
            }
            let wanted = args.dropFirst().joined(separator: " ")
            guard let item = Int(wanted).flatMap({ menu.items.indices.contains($0 - 1) ? menu.items[$0 - 1] : nil })
                ?? menu.items.first(where: { $0.title == wanted }) else {
                throw ControlError("メニューに「\(wanted)」がない。番号か項目名で指定すること: "
                    + menu.items.map(\.title).joined(separator: " / "))
            }
            guard item.isEnabled else { throw ControlError("「\(item.title)」は今は選べない。") }
            guard !item.hasSubmenu else { throw ControlError("「\(item.title)」は下にメニューを持つ項目で、選べない。") }
            menu.choose(item)
            return await afterUIAction("chose \"\(item.title)\" from \(menu.label)")

        case "window-size":
            guard let window = windows.mainWindow() else { throw ControlError("窓が出ていない。") }
            let width = try integer(try argument(args, 0, "幅"), "幅")
            let height = try integer(try argument(args, 1, "高さ"), "高さ")
            windows.resize(window, width: width, height: height)
            return await afterUIAction("resized to \(width)x\(height)")

        case "appearance":
            return try windows.appearance(args.first)

        case "key":
            try await windows.pressKey(try argument(args, 0, "キー"))
            return state.ui()

        case "type":
            let replace = takeFlag("--replace", from: &args)
            guard !args.isEmpty else { throw ControlError("打つ文字列がない。例: type github") }
            try await windows.typeText(args.joined(separator: " "), replacing: replace)
            try? await Task.sleep(for: .milliseconds(300))
            return state.ui()

        case "window-screenshot":
            return try windows.screenshot(to: args.first)

        case "activate":
            windows.activate()
            return "activated pid \(getpid())"

        default:
            return nil
        }
    }

    /// 窓まわりを操作したあと、画面の更新とポップオーバーの出し入れを待ってから様子を添えて返す。
    private func afterUIAction(_ result: String) async -> String {
        try? await Task.sleep(for: .milliseconds(300))
        return result + "\n" + state.ui()
    }

    /// ブックマークとダウンロード。
    /// 普通のタブの組を作る・出す・タブを移す。
    private func groupCommand(_ command: String, _ args: inout [String], _ options: Options) throws -> String? {
        switch command {
        case "groups":
            return try state.groups(of: store)

        case "group-new":
            let moving = takeFlag("--move", from: &args)
            let store = try store
            let name = args.joined(separator: " ")
            guard store.group(named: name) == nil else { throw ControlError("グループ「\(name)」はもうある。") }
            var tabID: Tab.ID?
            if moving {
                let tab = try target(options)
                guard store.groupKey(of: tab.id) != nil else { throw ControlError("ブックマークのページはグループに入れられない。") }
                tabID = tab.id
            }
            guard store.createGroup(named: name, moving: tabID) != nil else { throw ControlError("グループの名前がない。") }
            return state.groups(of: store)

        case "group-show":
            let store = try store
            store.showGroup(try groupID(named: args.joined(separator: " "), in: store))
            return state.groups(of: store) + "\n" + state.tabs(of: store)

        case "group-move":
            let store = try store
            let tab = try target(options)
            guard store.groupKey(of: tab.id) != nil else { throw ControlError("ブックマークのページはグループに入れられない。") }
            store.move(tab.id, to: try groupID(named: args.joined(separator: " "), in: store))
            return state.groups(of: store) + "\n" + state.tabs(of: store)

        case "group-rename":
            let store = try store
            guard let id = try groupID(named: try argument(args, 0, "グループ名"), in: store) else {
                throw ControlError("グループなしの名前は変えられない。")
            }
            let name = args.dropFirst().joined(separator: " ")
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ControlError("新しい名前がない。") }
            store.renameGroup(id, to: name)
            return state.groups(of: store)

        case "group-bar":
            let store = try store
            guard let id = try groupID(named: try argument(args, 0, "グループ名"), in: store) else {
                throw ControlError("グループなしはバーに出せない。")
            }
            let value = try argument(args, 1, "on か off ")
            guard ["on", "off"].contains(value) else { throw ControlError("on か off で指定すること: \(value)") }
            store.setShowsInBar(id, value == "on")
            return state.groups(of: store)

        case "group-remove":
            let store = try store
            guard let id = try groupID(named: args.joined(separator: " "), in: store) else {
                throw ControlError("グループなしは解けない。")
            }
            store.removeGroup(id)
            return state.groups(of: store)

        default:
            return nil
        }
    }

    /// 名前の組。`none` は組に入っていないタブ（`nil`）。
    private func groupID(named name: String, in store: TabStore) throws -> UUID? {
        guard !name.isEmpty else { throw ControlError("グループ名がない（組に入っていないタブは none）。") }
        if name == "none" { return nil }
        guard let group = store.group(named: name) else {
            throw ControlError("グループ「\(name)」はない。`groups` で一覧を見ること。")
        }
        return group.id
    }

    private func bookmarkCommand(_ command: String, _ args: inout [String], _ options: Options) async throws -> String? {
        switch command {
        case "bookmarks":
            return try state.bookmarks(of: store)

        case "bookmark-add":
            let name = try takeOption("--name", from: &args)
            let folderName = try takeOption("--folder", from: &args)
            let store = try store
            let folderID = folderName.map { store.bookmarks.folder(named: $0)?.id ?? store.bookmarks.addFolder(named: $0).id }
            if args.isEmpty {
                let tab = try target(options)
                guard store.bookmarkID(of: tab) == nil else { throw ControlError("このタブはすでにブックマークのページ。") }
                guard store.pin(tab.id, title: name, folder: folderID) != nil else {
                    throw ControlError("このタブにはまだページがない。")
                }
            } else {
                let url = try url(from: args)
                store.bookmarks.add(title: name ?? "", url: url, folder: folderID)
            }
            return try state.bookmarks(of: self.store)

        case "bookmark-open":
            let store = try store
            let id = try bookmarkID(try argument(args, 0, "ブックマークの番号"), in: store)
            guard let tab = store.activate(bookmark: id) else { throw ControlError("フォルダは開けない。中のブックマークの番号を指定すること。") }
            return try await pages.settled(tab)

        case "bookmark-remove":
            let store = try store
            store.removeBookmark(try bookmarkID(try argument(args, 0, "ブックマークの番号"), in: store))
            return try state.bookmarks(of: self.store)

        case "downloads":
            if options.clear { model.downloads.clearFinished() }
            return state.downloads()

        default:
            return nil
        }
    }

    /// `bookmarks` の一覧に出る番号を、ブックマークかフォルダのIDに引き直す。
    private func bookmarkID(_ text: String, in store: TabStore) throws -> UUID {
        try StateText.bookmarkID(try integer(text, "ブックマークの番号"), in: store)
    }

    /// サイトごとの設定と広告ブロック。
    private func siteCommand(_ command: String, _ args: inout [String], _ options: Options) async throws -> String? {
        switch command {
        case "settings":
            if let name = args.first {
                let value = try argument(args, 1, "値")
                switch (name, value) {
                case ("popups", "block"): settings.blocksPopups = true
                case ("popups", "allow"): settings.blocksPopups = false
                case ("popups", _): throw ControlError("popups の値は block か allow。")
                default: throw ControlError("そういう設定はない: \(name)。設定は popups だけ。")
                }
            }
            return "popups: \(settings.blocksPopups ? "block" : "allow")"

        case "adblock":
            let blocker = try contentBlocker()
            // 起動直後はまだコンパイル中のことがあるので、準備が済むのを待ってから答える。
            await blocker.settle()
            return state.adBlock(blocker)

        case "hide":
            guard !args.isEmpty else { throw ControlError("CSSセレクタがない。例: hide \".ad-banner\"") }
            let selector = args.joined(separator: " ")
            let blocker = try contentBlocker()
            let tab = try target(options)
            let site = try self.site(of: tab)
            let count = try await pages.hide(selector, on: tab)
            await blocker.hide(selector, on: site)
            return "hid \(count) element(s) on \(site): \(selector)"

        case "unhide":
            let blocker = try contentBlocker()
            let tab = try target(options)
            let site = try self.site(of: tab)
            let count = await blocker.unhideAll(on: site)
            tab.reload()
            return "restored \(count) selector(s) on \(site)\n" + (try await pages.settled(tab))

        default:
            return nil
        }
    }

    private func contentBlocker() throws -> ContentBlocker {
        guard let blocker = model.contentBlocker else { throw ControlError("広告ブロックが付いていない。") }
        return blocker
    }

    private func site(of tab: Tab) throws -> String {
        guard let site = tab.url.flatMap(HiddenElementStore.site(for:)) else {
            throw ControlError("このページでは要素を隠せない（http(s) か file のページのみ）。")
        }
        return site
    }

    /// プロファイルの一覧、作る、開く。
    private func profileCommand(_ command: String, _ args: inout [String]) async throws -> String? {
        switch command {
        case "profiles":
            return state.profiles()

        case "profile-new":
            let name = try model.create(try argument(args, 0, "プロファイルの名前"))
            return "created \(name)\n" + state.profiles()

        case "profile-open":
            let name = try argument(args, 0, "プロファイルの名前")
            let before = windows.arrangement()
            let result: String
            switch try model.openProfile(name) {
            case .alreadyHere:
                return "already here: \(name)"
            case .broughtToFront:
                result = "brought to front: \(name)"
            case .shownInEmptyWindow:
                result = "opened in this window: \(name)"
            case .openedInNewWindow:
                windows.orderNewWindowsFront(since: before)
                result = "opened in new window: \(name)"
            }
            return try result + "\n" + state.tabs(of: store)

        default:
            return nil
        }
    }

    /// 実体そのもの（記録、計測、終了）。
    private func appCommand(_ command: String, _ args: inout [String], _ options: Options) async throws -> String? {
        switch command {
        case "app-logs":
            let seconds = try takeOption("--seconds", from: &args).map { text in
                guard let value = Double(text), value > 0 else { throw ControlError("--seconds は正の数で指定すること: \(text)") }
                return value
            }
            return try await state.appLogs(seconds: seconds, limit: options.limit ?? 50)

        case "stats":
            let seconds = try takeOption("--seconds", from: &args).map { text in
                guard let value = Double(text), (0.1...60).contains(value) else {
                    throw ControlError("--seconds は 0.1〜60 の数で指定すること: \(text)")
                }
                return value
            } ?? 0.5
            let json = takeFlag("--json", from: &args)
            return try await state.stats(seconds: seconds, json: json)

        case "pid":
            return "pid \(getpid())"

        case "quit":
            // 終わると決めたら、もう命令を受けない。終わるまでの間に届いた命令は、答える前に終わってしまい
            // 「応答がなかった」になっていた。待ち受けをやめれば、次の hanectl は新しい実体を起こす。
            listener?.stop()
            listener = nil
            // 応答を返し終えてから終了する。
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                // シート（アラート）が出ていると終了が黙って取りやめになるので、先に閉じる。
                for window in NSApp.windows {
                    if let sheet = window.attachedSheet { window.endSheet(sheet) }
                }
                NSApp.terminate(nil)
                // ここへ戻るのは終了が取りやめになったときだけ。外から操作できない実体を残さないよう、待ち受けを戻す。
                start()
            }
            // どの実体を止めたかを残す。同じプロファイルの古い実体が残っていて、思わぬ方を止めたことがあった。
            let executable = Bundle.main.executableURL?.path(percentEncoded: false) ?? "?"
            return "quitting pid \(getpid()) (\(executable))"

        default:
            return nil
        }
    }

    // MARK: 引数

    /// `--tab` で指したタブか、なければ選ばれているタブ。
    private func target(_ options: Options) throws -> Tab {
        try tab(numbered: options.tabNumber)
    }

    private func tab(numbered number: Int?) throws -> Tab {
        guard let number else {
            guard let selected = try store.selected else { throw ControlError("タブがない。") }
            return selected
        }
        guard let tab = try store.allTabs.first(where: { $0.number == number }) else {
            throw ControlError("タブ \(number) はない。`tabs` で一覧を見ること。")
        }
        return tab
    }

    private func url(from args: [String]) throws -> URL {
        guard let url = AddressResolver.resolve(args.joined(separator: " ")) else {
            throw ControlError("URLまたは検索語がない。")
        }
        return url
    }

    private func takeOption(_ name: String, from args: inout [String]) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard args.indices.contains(index + 1) else { throw ControlError("\(name) に値がない。") }
        let value = args[index + 1]
        args.removeSubrange(index...index + 1)
        return value
    }

    private func takeFlag(_ name: String, from args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: name) else { return false }
        args.remove(at: index)
        return true
    }

    private func argument(_ args: [String], _ index: Int, _ name: String) throws -> String {
        guard args.indices.contains(index) else { throw ControlError("\(name)がない。") }
        return args[index]
    }

    private func integer(_ text: String, _ name: String) throws -> Int {
        guard let value = Int(text) else { throw ControlError("\(name)は整数で指定すること: \(text)") }
        return value
    }
}

struct ControlError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    /// `ControlError` 以外の失敗を、答えに載せる文に直す。ページのスクリプトの例外はその文面を出す。
    static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return "JavaScriptエラー: \(message)"
        }
        return nsError.localizedDescription
    }
}
