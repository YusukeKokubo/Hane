import AppKit
import ControlWire
import Foundation
import OSLog
import WebKit

/// 外部からの操作要求を、タブとページへの操作に置き換える。
///
/// 命令の一覧と書式は `ControlHelp` の文面が正本。
@MainActor
final class ControlService {
    private let model: BrowserModel
    private let settings: SettingsStore
    /// 要素の控えを置く実行環境。ページ自身のスクリプトからは見えない。
    /// 子フレームの窓をアプリへ渡せる（`createJSHandle`）ようにして、iframe の中でも走らせられるようにしてある。
    /// 設定から作った実行環境は名前で引き直せないので、持ち続ける。
    /// ページへの命令が初めて来たときに作る。外から操作しない普段の起動では、この口に触れない。
    private lazy var world = {
        let configuration = WKContentWorld.Configuration()
        configuration.jsHandleCreationEnabled = true
        return WKContentWorld(configuration: configuration)
    }()
    /// `ui-snapshot` で振った番号と、窓まわりの部品の対応。
    private let windowElements: WindowElements
    /// アプリの起動とほぼ同時に作られるので、起動した時刻として使う。
    private let launchedAt = Date()
    /// 操作用ソケットの待ち受け。`quit` で止める。
    private var listener: ControlServer.Listener?

    private static let loadTimeout: Duration = .seconds(30)
    /// `hanectl` は 120 秒答えがないと落ちるので、条件を待つ上限はそれより短くする。
    private static let waitTimeoutLimit: Double = 100

    init(model: BrowserModel, settings: SettingsStore = SettingsStore()) {
        self.model = model
        self.settings = settings
        windowElements = WindowElements { [weak model] in model?.currentWindow }
    }

    /// テスト用。渡したタブ管理を持つ使い捨ての実体として振る舞う。
    convenience init(store: TabStore) {
        self.init(model: BrowserModel(store: store))
    }

    /// 今のプロファイル（最後に前へ出たプロファイルの窓）のタブ管理。窓を移ったりプロファイルを切り替えたりすると入れ替わるので、掴んでおかずに毎回読む。
    private var store: TabStore { model.store }

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
            return ControlResponse(ok: false, output: Self.describe(error))
        }
    }

    // MARK: 命令の振り分け

    private func run(_ rawArgs: [String]) async throws -> String {
        var args = rawArgs
        let tabNumber = try takeOption("--tab", from: &args).map { try integer($0, "--tab") }
        let limit = try takeOption("--limit", from: &args).map { try integer($0, "--limit") }
        let fullPage = takeFlag("--full", from: &args)
        let clear = takeFlag("--clear", from: &args)
        guard let command = args.first else { return ControlHelp.text }
        args.removeFirst()

        func target() throws -> Tab { try tab(numbered: tabNumber) }

        switch command {
        case "help", "--help", "-h":
            return ControlHelp.text

        case "tabs":
            return store.allTabs.map(describe).joined(separator: "\n")

        case "new":
            if args.isEmpty {
                return describe(store.newTab())
            }
            let tab = store.open(URLRequest(url: try url(from: args)))
            return try await settled(tab)

        case "select":
            let tab = try tab(numbered: try integer(try argument(args, 0, "タブ番号"), "タブ番号"))
            store.selectedID = tab.id
            return describe(tab)

        case "close":
            let number = try args.first.map { try integer($0, "タブ番号") } ?? tabNumber
            let tab = try tab(numbered: number)
            // ブックマークのページは閉じてもウインドウが残るので、最後の1枚でも閉じてよい。
            guard store.allTabs.count > 1 || store.bookmarkID(of: tab) != nil else {
                throw ControlError("最後の1枚は閉じられない（ウインドウが閉じてアプリが終了するため）。")
            }
            store.close(tab.id)
            return "closed tab \(tab.number)\n" + store.allTabs.map(describe).joined(separator: "\n")

        case "open":
            let tab = try target()
            tab.load(URLRequest(url: try url(from: args)))
            return try await settled(tab)

        case "back":
            let tab = try target()
            guard tab.canGoBack else { throw ControlError("これより前の履歴はない。") }
            tab.goBack()
            return try await settled(tab)

        case "forward":
            let tab = try target()
            guard tab.canGoForward else { throw ControlError("これより先の履歴はない。") }
            tab.goForward()
            return try await settled(tab)

        case "reload":
            let tab = try target()
            tab.reload()
            return try await settled(tab)

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
            let path = try takeOption("--frame", from: &args).map(Self.framePath)
            if let extra = args.first { throw ControlError("wait に余分な引数がある: \(extra)") }
            let conditions = WaitConditions(text: text, selector: selector, script: script, gone: gone)
            guard !conditions.isEmpty else {
                if gone || path != nil { throw ControlError("--gone と --frame には、--text、--selector、--js のどれかが要る。") }
                return try await settled(try target())
            }
            return try await waitFor(conditions, in: path, timeout: timeout, on: try target())

        case "sleep":
            let number = try args.first.map { try integer($0, "タブ番号") } ?? tabNumber
            let tab = try tab(numbered: number)
            guard tab.id != store.selectedID else { throw ControlError("画面に出ているタブは眠らせられない。先に別のタブを選ぶこと。") }
            guard tab.sleep() else { throw ControlError("このタブはページを持っていない（もう眠っているか、まだ何も開いていない）。") }
            return store.allTabs.map(describe).joined(separator: "\n")

        case "snapshot":
            let tab = try target()
            return describe(tab) + "\n" + (try await snapshot(of: tab, limit: limit ?? 300))

        case "text":
            let tab = try target()
            let path = try takeOption("--frame", from: &args).map(Self.framePath)
            let frame = try await frame(at: path ?? [], on: tab)
            let body = try await script(PageScripts.text, ["limit": limit ?? 50_000], on: tab, in: frame.info)
            return describe(tab) + (path.map { "\n" + Self.describeFrame(path: $0, frame.info) } ?? "") + "\n\n" + body

        case "click":
            let ref = try integer(try argument(args, 0, "要素の番号"), "要素の番号")
            return try await act("click", ref: ref, text: "", on: try target())

        case "fill":
            let ref = try integer(try argument(args, 0, "要素の番号"), "要素の番号")
            guard args.count >= 2 else { throw ControlError("入力する文字列がない。例: fill 3 \"hello\"") }
            return try await act("fill", ref: ref, text: args.dropFirst().joined(separator: " "), on: try target())

        case "press":
            let key = try argument(args, 0, "キー名")
            let ref = try args.count >= 2 ? integer(args[1], "要素の番号") : 0
            return try await act("press", ref: ref, text: key, on: try target())

        case "page-click":
            let right = takeFlag("--right", from: &args)
            let modifiers = try takeOption("--with", from: &args).map { try Self.modifiers(from: $0.lowercased().split(separator: "+").map(String.init)) } ?? []
            return try await pageClick(try argument(args, 0, "要素の番号か位置"), right: right, modifiers: modifiers, on: try target())

        case "page-hover":
            return try await pageHover(try argument(args, 0, "要素の番号か位置"), on: try target())

        case "page-key":
            guard !args.isEmpty else { throw ControlError("キーがない。例: page-key j、page-key g g、page-key shift+g") }
            return try await pageKeys(args, on: try target())

        case "eval":
            let path = try takeOption("--frame", from: &args).map(Self.framePath)
            guard !args.isEmpty else { throw ControlError("JavaScriptがない。例: eval \"document.title\"") }
            let tab = try target()
            let frame = try await frame(at: path ?? [], on: tab)
            return try await evaluate(args.joined(separator: " "), on: tab, in: frame.info)

        case "ui":
            return describeUI()

        case "ui-snapshot":
            return try await windowElements.snapshot()

        case "ui-click":
            let result = try windowElements.click(try await windowElements.resolve(try argument(args, 0, "部品の番号か名前")))
            return await afterUIAction(result)

        case "ui-hover":
            let result = try windowElements.hover(try await windowElements.resolve(try argument(args, 0, "部品の番号か名前")))
            return await afterUIAction(result)

        case "ui-menu":
            let menu = try windowElements.menu(try await windowElements.resolve(try argument(args, 0, "部品の番号か名前")))
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
            guard let window = mainWindow() else { throw ControlError("窓が出ていない。") }
            let width = try integer(try argument(args, 0, "幅"), "幅")
            let height = try integer(try argument(args, 1, "高さ"), "高さ")
            // 左上を動かさずに大きさだけ変える（AppKit の座標は左下から測る）。
            var frame = window.frame
            frame.origin.y += frame.height - CGFloat(height)
            frame.size = CGSize(width: width, height: height)
            window.setFrame(frame, display: true)
            return await afterUIAction("resized to \(width)x\(height)")

        case "appearance":
            if let name = args.first {
                switch name {
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "system": NSApp.appearance = nil
                default: throw ControlError("外観は dark、light、system のどれか: \(name)")
                }
            }
            let effective = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
            return "appearance: \(effective)" + (NSApp.appearance == nil ? "（システムに従う）" : "（このアプリだけ固定。appearance system で戻す）")

        case "key":
            try sendKey(try argument(args, 0, "キー"))
            // 画面の更新とポップオーバーの出し入れを待ってから様子を返す。
            try? await Task.sleep(for: .milliseconds(300))
            return describeUI()

        case "type":
            let replace = takeFlag("--replace", from: &args)
            guard !args.isEmpty else { throw ControlError("打つ文字列がない。例: type github") }
            try await typeText(args.joined(separator: " "), replacing: replace)
            try? await Task.sleep(for: .milliseconds(300))
            return describeUI()

        case "history":
            let recent = store.history.entries.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(limit ?? 30)
            guard !recent.isEmpty else { return "（履歴なし）" }
            return recent.map { entry in
                "\(Self.clock.string(from: entry.lastVisit)) typed \(entry.typedCount) visits \(entry.visitCount)  "
                    + "\(entry.title.isEmpty ? "(無題)" : entry.title) — \(entry.url.absoluteString)"
            }.joined(separator: "\n")

        case "bookmarks":
            return describeBookmarks()

        case "downloads":
            if clear { store.downloads.clearFinished() }
            return describeDownloads()

        case "bookmark-add":
            let name = try takeOption("--name", from: &args)
            let folderName = try takeOption("--folder", from: &args)
            let folderID = folderName.map { store.bookmarks.folder(named: $0)?.id ?? store.bookmarks.addFolder(named: $0).id }
            if args.isEmpty {
                let tab = try target()
                guard store.bookmarkID(of: tab) == nil else { throw ControlError("このタブはすでにブックマークのページ。") }
                guard store.pin(tab.id, title: name, folder: folderID) != nil else {
                    throw ControlError("このタブにはまだページがない。")
                }
            } else {
                let url = try url(from: args)
                store.bookmarks.add(title: name ?? "", url: url, folder: folderID)
            }
            return describeBookmarks()

        case "bookmark-open":
            let id = try bookmarkID(try argument(args, 0, "ブックマークの番号"))
            guard let tab = store.activate(bookmark: id) else { throw ControlError("フォルダは開けない。中のブックマークの番号を指定すること。") }
            return try await settled(tab)

        case "bookmark-remove":
            store.removeBookmark(try bookmarkID(try argument(args, 0, "ブックマークの番号")))
            return describeBookmarks()

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
            return describeAdBlock(blocker)

        case "hide":
            guard !args.isEmpty else { throw ControlError("CSSセレクタがない。例: hide \".ad-banner\"") }
            let selector = args.joined(separator: " ")
            let blocker = try contentBlocker()
            let tab = try target()
            let site = try self.site(of: tab)
            let reply = try await script(PageScripts.hide, ["selector": selector], on: tab)
            let object = reply.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if let message = object?["error"] as? String { throw ControlError(message) }
            await blocker.hide(selector, on: site)
            return "hid \(object?["count"] as? Int ?? 0) element(s) on \(site): \(selector)"

        case "unhide":
            let blocker = try contentBlocker()
            let tab = try target()
            let site = try self.site(of: tab)
            let count = await blocker.unhideAll(on: site)
            tab.reload()
            return "restored \(count) selector(s) on \(site)\n" + (try await settled(tab))

        case "logs":
            let tab = try target()
            let entries = tab.log.entries.suffix(limit ?? 50)
            let listing = entries.isEmpty
                ? "（記録なし）"
                : entries.map { "\(Self.clock.string(from: $0.date)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
            if clear { tab.log.clear() }
            return describe(tab) + "\n" + listing

        case "app-logs":
            let seconds = try takeOption("--seconds", from: &args).map { text in
                guard let value = Double(text), value > 0 else { throw ControlError("--seconds は正の数で指定すること: \(text)") }
                return value
            }
            // 読むのは命令のときだけ。`OSLogStore` は一度に 1 秒近くかかり、メインスレッドで読むと窓が止まる。
            let since = seconds.map { Date().addingTimeInterval(-$0) } ?? launchedAt.addingTimeInterval(-1)
            let lines = try await Task.detached { try Self.readAppLog(since: since) }.value.suffix(limit ?? 50)
                .map { "\(Self.clock.string(from: $0.date)) \($0.text)" }
            return "app: pid \(getpid())\n" + (lines.isEmpty ? "（記録なし）" : lines.joined(separator: "\n"))

        case "requests":
            let json = takeFlag("--json", from: &args)
            let filter = RequestFilter(
                url: try takeOption("--url", from: &args)?.lowercased(),
                types: try takeOption("--type", from: &args).map { Set($0.lowercased().split(separator: ",").map(String.init)) })
            let tab = try target()
            let frames = try await requests(of: tab)
            return json
                ? try Self.requestsJSON(frames, tab: tab, filter: filter, limit: limit ?? 200)
                : describe(tab) + "\n" + Self.describeRequests(frames, filter: filter, limit: limit ?? 200)

        case "stats":
            let seconds = try takeOption("--seconds", from: &args).map { text in
                guard let value = Double(text), (0.1...60).contains(value) else {
                    throw ControlError("--seconds は 0.1〜60 の数で指定すること: \(text)")
                }
                return value
            } ?? 0.5
            let json = takeFlag("--json", from: &args)
            let all = store.allTabs
            let pages = Dictionary(grouping: all.filter(\.hasContent)) { $0.page.flatMap(PageProcess.identifier(of:)) }
            let byProcess = pages.reduce(into: [pid_t: [Int]]()) { result, entry in
                if let pid = entry.key { result[pid] = entry.value.map(\.number) }
            }
            let report = await ProcessStats.measure(for: .milliseconds(Int(seconds * 1000)), tabs: byProcess)
            let tabs = StatsTabs(
                total: all.count, withContent: all.count { $0.hasContent }, asleep: all.count { $0.isAsleep },
                bookmarkPages: store.bookmarkTabs.count)
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(StatsOutput(report: report, tabs: tabs))
                return String(decoding: data, as: UTF8.self)
            }
            return ProcessStats.table(report)
                + "\ntabs: \(tabs.total)（うちページあり \(tabs.withContent)、眠っている \(tabs.asleep)、ブックマークのページ \(tabs.bookmarkPages)）"
                + (isStaleBuild ? "\n" + describeBuild() : "")

        case "pid":
            return "pid \(getpid())"

        case "activate":
            // 同じ実体を二重に起動しようとしたときに、後から起きた方が頼んでくる。最小化や隠れていれば戻す。
            NSApp.unhide(nil)
            if let window = model.currentWindow ?? NSApp.windows.first(where: \.canBecomeMain) {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
            return "activated pid \(getpid())"

        case "profiles":
            return describeProfiles()

        case "profile-new":
            let name = try model.create(try argument(args, 0, "プロファイルの名前"))
            return "created \(name)\n" + describeProfiles()

        case "profile-open":
            let name = try argument(args, 0, "プロファイルの名前")
            guard try model.switchTo(name) else { return "already here: \(name)" }
            return "switched: \(name)\n" + store.allTabs.map(describe).joined(separator: "\n")

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

        case "screenshot":
            return try await screenshot(of: try target(), to: args.first, fullPage: fullPage)

        case "window-screenshot":
            return try windowScreenshot(to: args.first)

        default:
            throw ControlError("未知の命令: \(command)。`hanectl help` で一覧を見ること。")
        }
    }

    // MARK: ページへの操作

    private func act(_ action: String, ref: Int, text: String, on tab: Tab) async throws -> String {
        // 以前の読み込み失敗が残っていると、この操作の結果と取り違える。
        tab.dismissFailure()
        let (reply, _) = try await scriptFollowingFrames(PageScripts.act, ["ref": ref, "action": action, "text": text], on: tab)
        if let message = reply["error"] as? String {
            throw ControlError(message)
        }
        // クリックや送信でページが切り替わることがあるので、落ち着くまで待つ。
        return try await settled(tab)
    }

    // MARK: iframe の中

    /// 子フレームの中を読んだり操作したりするための、フレームとその位置。`info` が nil なら主フレーム。
    private struct Frame {
        var info: WKFrameInfo?
        /// フレームの中身の左上の位置（CSS の画素。主フレームの表示している範囲の左上から）。
        var offset = CGPoint.zero
        /// たどった各段で、外側のフレームの表示している範囲と、その中での子フレームの中身の左上。
        /// 押す位置が途中で切れていないかを確かめるため。
        var levels: [(viewport: CGSize, origin: CGPoint)] = []
    }

    /// 主フレーム（`from` が nil）か子フレームから、子フレームの順番（0から）をたどって、そのフレームを引く。
    ///
    /// 子フレームの窓をスクリプトから `WKJSHandle` として受け取り、WebKit にそのフレームを引き直させる。
    /// 命令が来たときだけ引くので、普段の閲覧ではフレームの一覧を持ち続けず、フレームごとの知らせも要らない。
    /// 別のオリジンのフレームも、ページのスクリプトからは触れないがアプリからは引ける。
    /// `every` なら、順番は見えていないものも含めた子フレームの並びで数える。
    private func frame(at path: [Int], from start: Frame = Frame(), on tab: Tab, reveal: Bool = false, every: Bool = false) async throws -> Frame {
        var frame = start
        for index in path {
            let value = try await scriptValue(PageScripts.frame, ["index": index, "reveal": reveal, "every": every], on: tab, in: frame.info)
            guard let object = value as? [String: Any] else { throw ControlError("フレームを引けなかった。") }
            if let message = object["error"] as? String { throw ControlError(message) }
            guard let handle = object["handle"] as? WKJSHandle, let info = await handle.windowProxyFrame else {
                throw ControlError("フレームを引けなかった（読み込み中か、ページが変わった）。snapshot を取り直すこと。")
            }
            let origin = CGPoint(x: object["left"] as? Double ?? 0, y: object["top"] as? Double ?? 0)
            let viewport = CGSize(width: object["width"] as? Double ?? 0, height: object["height"] as? Double ?? 0)
            frame.info = info
            frame.offset.x += origin.x
            frame.offset.y += origin.y
            frame.levels.append((viewport, origin))
        }
        return frame
    }

    /// スクリプトを主フレームで走らせ、子フレームへ下りるよう返ってきたら（`descend`）そのフレームで走らせ直す。
    /// 返事（JSON）と、下りた道筋（主フレームからの子フレームの順番）を返す。
    private func scriptFollowingFrames(
        _ body: String, _ arguments: [String: Any], on tab: Tab, reveal: Bool = false
    ) async throws -> (reply: [String: Any], path: [Int]) {
        var frame = Frame()
        var path: [Int] = []
        // 入れ子が深すぎるものや、下りた先でまた同じ所を指すおかしなページで回り続けないよう区切る。
        for _ in 0..<16 {
            let text = try await script(body, arguments, on: tab, in: frame.info)
            let reply = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            guard let descend = reply["descend"] as? [Int] else { return (reply, path) }
            frame = try await self.frame(at: descend, from: frame, on: tab, reveal: reveal)
            path += descend
        }
        throw ControlError("フレームの入れ子が深すぎる。")
    }

    /// 操作できる要素の一覧。iframe の中も、フレームごとに見出しを付けて、その iframe の行の後ろに続ける。
    /// 番号はページ全体で通しにし、子フレームの番号の範囲は主フレームに控える（`act` と `locate` が引く）。
    private func snapshot(of tab: Tab, limit: Int) async throws -> String {
        var listing = SnapshotListing(limit: limit)
        try await collect(into: &listing, frame: Frame(), path: [], on: tab)
        if !listing.ranges.isEmpty {
            _ = try await script("window.__frameRefs = ranges; return '';", ["ranges": listing.ranges], on: tab)
        }
        if listing.skipped > 0 { listing.lines.append("… ほか \(listing.skipped) 個の要素を省略（snapshot --limit <数> で増やせる）") }
        if listing.next == 1 { listing.lines.append("（操作できる要素は見つからなかった）") }
        return listing.lines.joined(separator: "\n")
    }

    private struct SnapshotListing {
        let limit: Int
        var lines: [String] = []
        var next = 1
        var skipped = 0
        /// 子フレームの番号の範囲と、そのフレームへの道筋。
        var ranges: [[String: Any]] = []
    }

    private func collect(into listing: inout SnapshotListing, frame: Frame, path: [Int], on tab: Tab) async throws {
        let value = try await scriptValue(
            PageScripts.snapshot, ["start": listing.next, "limit": max(0, listing.limit - listing.next + 1)], on: tab, in: frame.info)
        guard let object = value as? [String: Any] else { throw ControlError("一覧を読めなかった。") }
        let indent = String(repeating: "  ", count: path.count)
        listing.lines += (object["lines"] as? [String] ?? []).map { indent + $0 }
        let count = object["count"] as? Int ?? 0
        if !path.isEmpty, count > 0 {
            listing.ranges.append(["from": listing.next, "to": listing.next + count - 1, "path": path])
        }
        listing.next += count
        listing.skipped += object["skipped"] as? Int ?? 0

        for (index, label) in (object["frames"] as? [String] ?? []).enumerated() {
            let childPath = path + [index]
            let header = indent + Self.frameLabel(childPath) + ": " + label
            do {
                let child = try await self.frame(at: [index], from: frame, on: tab)
                listing.lines.append(header + (child.info?.request.url.map { " — " + $0.absoluteString } ?? ""))
                try await collect(into: &listing, frame: child, path: childPath, on: tab)
            } catch {
                // 読めないフレーム（読み込み中や、中身のない埋め込み）があっても、ほかは出す。
                let reason = (error as? ControlError)?.message ?? Self.describe(error)
                listing.lines.append(header + "（中を読めなかった: \(reason)）")
            }
        }
    }

    /// `snapshot` に出るフレームの名前（frame 1、frame 1.2 など）。
    private static func frameLabel(_ path: [Int]) -> String {
        "frame " + path.map { String($0 + 1) }.joined(separator: ".")
    }

    private static func describeFrame(path: [Int], _ info: WKFrameInfo?) -> String {
        frameLabel(path) + (info?.request.url.map { " — " + $0.absoluteString } ?? "")
    }

    /// `--frame 1.2` を子フレームの順番の並びにする。
    private static func framePath(_ text: String) throws -> [Int] {
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ ($0 ?? 0) > 0 }) else {
            throw ControlError("--frame は snapshot に出るフレームの番号（1 や 1.2）で指すこと: \(text)")
        }
        return numbers.map { $0! - 1 }
    }

    // MARK: 通信の記録

    /// 一つのフレームが読み込んだものと、要素が指しているのに記録がないもの。
    private struct FrameRequests {
        /// main、frame 1、frame 1.h1 など。
        var name: String
        /// iframe の名札（iframe#ad など）。主フレームは空。
        var element = ""
        var url = ""
        /// このフレームの時刻の起点（`performance.timeOrigin`。1970年からのミリ秒）。
        var origin: Double = 0
        var entries: [RequestEntry] = []
        var missing: [MissingResource] = []
        var bufferFull = false
        var error: String?
    }

    private struct RequestEntry {
        var type: String
        var url: String
        /// フレームの時刻の起点からのミリ秒。
        var start: Double
        var duration: Double
        var transfer: Double
        var encoded: Double
        var decoded: Double
        var transport: String
    }

    private struct MissingResource {
        var type: String
        var url: String
        var hint: String
    }

    private struct RequestFilter {
        /// 小文字にした部分一致。
        var url: String?
        var types: Set<String>?

        func matches(type: String, url: String) -> Bool {
            (types?.contains(type.lowercased()) ?? true) && (self.url.map { url.lowercased().contains($0) } ?? true)
        }
    }

    /// WebKit が一つの文書で持つ資源の記録の上限（Resource Timing の既定）。あふれた後の読み込みは記録されない。
    private static let resourceTimingCapacity = 250

    /// 主フレームから子フレームを（見えていないものも）辿り、フレームごとの通信の記録を集める。
    /// ページが自分で持っている記録を命令のときだけ読むので、普段の閲覧には何も足さない。
    private func requests(of tab: Tab) async throws -> [FrameRequests] {
        var frames: [FrameRequests] = []
        try await collectRequests(into: &frames, frame: Frame(), path: [], on: tab)
        return frames
    }

    private func collectRequests(into frames: inout [FrameRequests], frame: Frame, path: [String], element: String = "", on tab: Tab) async throws {
        let value = try await scriptValue(PageScripts.requests, on: tab, in: frame.info)
        guard let object = value as? [String: Any] else { throw ControlError("通信の記録を読めなかった。") }
        let name = path.isEmpty ? "main" : "frame " + path.joined(separator: ".")
        let number = { (key: String, from: [String: Any]) in (from[key] as? NSNumber)?.doubleValue ?? 0 }
        frames.append(FrameRequests(
            name: name, element: element,
            url: object["url"] as? String ?? "",
            origin: number("origin", object),
            entries: (object["entries"] as? [[String: Any]] ?? []).map { entry in
                RequestEntry(
                    type: entry["type"] as? String ?? "other", url: entry["url"] as? String ?? "",
                    start: number("start", entry), duration: number("duration", entry),
                    transfer: number("transfer", entry), encoded: number("encoded", entry), decoded: number("decoded", entry),
                    transport: entry["protocol"] as? String ?? "")
            },
            missing: (object["missing"] as? [[String: Any]] ?? []).map { item in
                MissingResource(type: item["type"] as? String ?? "", url: item["url"] as? String ?? "", hint: item["hint"] as? String ?? "")
            },
            bufferFull: Int(number("resources", object)) >= Self.resourceTimingCapacity))

        // 見えているものは snapshot と同じ番号で、見えていないものは h1、h2 と名付ける（--frame では指せない）。
        var hidden = 0
        for (index, child) in (object["frames"] as? [[String: Any]] ?? []).enumerated() {
            let visible = (child["visible"] as? NSNumber)?.intValue ?? -1
            let part: String
            if visible >= 0 {
                part = String(visible + 1)
            } else {
                hidden += 1
                part = "h\(hidden)"
            }
            let label = child["label"] as? String ?? ""
            // 入れ子が深すぎるおかしなページで回り続けないよう区切る。
            guard path.count < 16 else { continue }
            do {
                let next = try await self.frame(at: [index], from: frame, on: tab, every: true)
                try await collectRequests(into: &frames, frame: next, path: path + [part], element: label, on: tab)
            } catch {
                // 読めないフレームがあっても、ほかは出す。
                let reason = (error as? ControlError)?.message ?? Self.describe(error)
                frames.append(FrameRequests(name: "frame " + (path + [part]).joined(separator: "."), element: label, error: reason))
            }
        }
    }

    /// 絞り込んだ記録を、フレームをまたいで始まった順に並べ、上限までを選ぶ。
    /// 返すのはフレームごとの選んだ記録（主フレームの時刻の起点からのミリ秒つき）と、上限で省いた数。
    private static func selectRequests(
        _ frames: [FrameRequests], filter: RequestFilter, limit: Int
    ) -> (rows: [[(entry: RequestEntry, at: Double)]], omitted: Int) {
        let base = frames.first?.origin ?? 0
        var all: [(frame: Int, entry: RequestEntry, at: Double)] = []
        for (index, frame) in frames.enumerated() {
            for entry in frame.entries where filter.matches(type: entry.type, url: entry.url) {
                all.append((index, entry, frame.origin + entry.start - base))
            }
        }
        all.sort { $0.at < $1.at }
        let shown = all.prefix(max(0, limit))
        var rows = Array(repeating: [(entry: RequestEntry, at: Double)](), count: frames.count)
        for item in shown { rows[item.frame].append((item.entry, item.at)) }
        return (rows, all.count - shown.count)
    }

    private static func describeRequests(_ frames: [FrameRequests], filter: RequestFilter, limit: Int) -> String {
        let (rows, omitted) = selectRequests(frames, filter: filter, limit: limit)
        var lines: [String] = []
        for (index, frame) in frames.enumerated() {
            lines.append(frame.name + (frame.element.isEmpty ? "" : " (\(frame.element))") + (frame.url.isEmpty ? "" : " — " + frame.url))
            if let error = frame.error {
                lines.append("  （中を読めなかった: \(error)）")
                continue
            }
            if frame.bufferFull {
                lines.append("  （資源の記録が上限の \(resourceTimingCapacity) 件に達している。これより後の読み込みは記録されず、not loaded に誤って出ることもある）")
            }
            if rows[index].isEmpty {
                let matched = frame.entries.contains { filter.matches(type: $0.type, url: $0.url) }
                lines.append(matched ? "  （上限で省いた）" : "  （記録なし）")
            }
            for (entry, at) in rows[index] {
                lines.append("  " + pad("+\(Int(at.rounded()))ms", 9, right: true) + " " + pad("\(Int(entry.duration.rounded()))ms", 7, right: true)
                    + " " + pad(byteCount(entry), 7, right: true) + "  " + pad(entry.type, 13) + " " + clip(entry.url, 300))
            }
        }
        if omitted > 0 { lines.append("… ほか \(omitted) 件を省略（requests --limit <数> で増やせる）") }

        let missing = frames.flatMap { frame in frame.missing.filter { filter.matches(type: $0.type, url: $0.url) }.map { (frame.name, $0) } }
        lines.append("")
        if missing.isEmpty {
            lines.append("not loaded: なし")
        } else {
            lines.append("not loaded（要素が指しているのに読み込んだ記録がないもの。広告ブロックで止められたか、つながらなかったか、まだ読み込み中）:")
            let width = missing.map(\.0.count).max() ?? 0
            for (name, item) in missing {
                lines.append("  " + pad(name, width) + "  " + pad(item.type, 6) + " " + clip(item.url, 300) + (item.hint.isEmpty ? "" : " — " + item.hint))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func requestsJSON(_ frames: [FrameRequests], tab: Tab, filter: RequestFilter, limit: Int) throws -> String {
        let (rows, omitted) = selectRequests(frames, filter: filter, limit: limit)
        let tenth = { (value: Double) in (value * 10).rounded() / 10 }
        let output: [String: Any] = [
            "tab": tab.number,
            "omitted": omitted,
            "frames": frames.enumerated().map { index, frame -> [String: Any] in
                var object: [String: Any] = ["frame": frame.name, "url": frame.url]
                if !frame.element.isEmpty { object["element"] = frame.element }
                if let error = frame.error {
                    object["error"] = error
                    return object
                }
                object["bufferFull"] = frame.bufferFull
                object["requests"] = rows[index].map { entry, at -> [String: Any] in
                    [
                        "type": entry.type, "url": entry.url, "start": tenth(at), "duration": tenth(entry.duration),
                        "transferSize": Int(entry.transfer), "encodedBodySize": Int(entry.encoded),
                        "decodedBodySize": Int(entry.decoded), "protocol": entry.transport,
                    ]
                }
                object["notLoaded"] = frame.missing.filter { filter.matches(type: $0.type, url: $0.url) }.map {
                    ["type": $0.type, "url": $0.url, "hint": $0.hint]
                }
                return object
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// 運んだ大きさ。0 でも本体の大きさが分かればキャッシュから読んだもの。どちらも 0 なら分からない
    /// （別のオリジンで Timing-Allow-Origin がないもの、メモリのキャッシュから読んだものなど）。
    private static func byteCount(_ entry: RequestEntry) -> String {
        if entry.transfer > 0 { return bytes(entry.transfer) }
        if entry.encoded > 0 { return "cache" }
        return "-"
    }

    private static func bytes(_ value: Double) -> String {
        if value < 1024 { return "\(Int(value))B" }
        if value < 1024 * 1024 { return String(format: "%.1fKB", value / 1024) }
        return String(format: "%.1fMB", value / 1024 / 1024)
    }

    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        guard text.count < width else { return text }
        let space = String(repeating: " ", count: width - text.count)
        return right ? space + text : text + space
    }

    private static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? text.prefix(length - 1) + "…" : text
    }

    // MARK: ページへの本物の入力

    /// 本物の入力を渡せるページ。画面に出ているタブのページでなければ断る（隠れた Web ビューは入力を受けない）。
    private func inputPage(of tab: Tab) throws -> Page {
        guard let page = tab.page else { throw ControlError("このタブにはまだページがない。先に `open <URL>` を行うこと。") }
        guard tab.id == store.selectedID else {
            throw ControlError("画面に出ているタブにしか入力を渡せない。先に `select \(tab.number)` を行うこと。")
        }
        guard page.canReceiveInput else { throw ControlError("ページが窓に出ていない。") }
        return page
    }

    /// `snapshot` の番号か `x,y`（CSS の画素。表示している範囲の左上から）で指された位置と、そこで事象を受ける要素。
    /// 番号の要素が画面の外なら、真ん中へスクロールしてから位置を測る。
    private func locate(_ reference: String, on tab: Tab) async throws -> (point: CGPoint, target: String) {
        var arguments: [String: Any] = ["ref": 0, "x": 0, "y": 0]
        if let ref = Int(reference) {
            arguments["ref"] = ref
        } else {
            let parts = reference.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let x = parts[0], let y = parts[1] else {
                throw ControlError("要素の番号か、x,y の位置で指すこと: \(reference)")
            }
            arguments["x"] = x
            arguments["y"] = y
        }
        // 子フレームの要素なら、外側のフレームで iframe を表示している範囲へ出してから、中で要素を測る。
        let (object, path) = try await scriptFollowingFrames(PageScripts.locate, arguments, on: tab, reveal: true)
        if let message = object["error"] as? String { throw ControlError(message) }
        guard let x = object["x"] as? Double, let y = object["y"] as? Double else { throw ControlError("位置を測れなかった。") }
        let point = CGPoint(x: x, y: y)
        let target = object["target"] as? String ?? ""
        guard !path.isEmpty else { return (point, target) }

        // 中で要素をスクロールすると外側も動くことがあるので、測り終えてから iframe の位置を測り直す。
        let frame = try await frame(at: path, on: tab)
        var inner = point
        for level in frame.levels.reversed() {
            inner.x += level.origin.x
            inner.y += level.origin.y
            guard inner.x >= 0, inner.y >= 0, inner.x < level.viewport.width, inner.y < level.viewport.height else {
                throw ControlError("番号 \(reference) の要素は \(Self.frameLabel(path)) の中にあるが、外側のフレームの表示している範囲から外れていて押せない。")
            }
        }
        return (inner, target + " in " + Self.frameLabel(path))
    }

    private func pageClick(_ reference: String, right: Bool, modifiers: NSEvent.ModifierFlags, on tab: Tab) async throws -> String {
        let page = try inputPage(of: tab)
        let (point, target) = try await locate(reference, on: tab)
        tab.dismissFailure()
        let menus = MenuCatcher()
        defer { menus.stop() }
        guard page.click(at: point, right: right, modifiers: modifiers) else { throw ControlError("ページへマウスの事象を渡せなかった。") }
        var lines = [(right ? "right-clicked " : "clicked ") + target + " at \(Int(point.x)),\(Int(point.y))"]
        let state = try await settled(tab)
        // メニューはページの返事を待ってから出るので、少し遅れて来る（試したときは20ミリ秒以内）。
        // 出ないことも多い（⌥右クリックの要素選びなど）ので、待ちすぎないよう区切る。右クリックは出やすいので長めに待つ。
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(right ? 500 : 100)
        while menus.items == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let items = menus.items {
            lines.append("menu (出たのですぐ閉じた。項目は選べない): " + (items.isEmpty ? "(項目なし)" : items.joined(separator: " / ")))
        }
        return (lines + [state]).joined(separator: "\n")
    }

    private func pageHover(_ reference: String, on tab: Tab) async throws -> String {
        let page = try inputPage(of: tab)
        let (point, target) = try await locate(reference, on: tab)
        guard page.moveMouse(to: point) else { throw ControlError("ページへマウスの事象を渡せなかった。") }
        try? await Task.sleep(for: .milliseconds(200))
        return "hovering \(target) at \(Int(point.x)),\(Int(point.y))"
            + (NSApp.isActive ? "" : "\n（アプリが裏にいるので、WebKit がポインタの動きを捨てて、ページには届かない。HANE_LAUNCH=front で起こして試すこと）")
    }

    private func pageKeys(_ specs: [String], on tab: Tab) async throws -> String {
        let page = try inputPage(of: tab)
        // 先に全部読んでから送る。途中で書き損じが見つかって半端に送らないため。
        let keys = try specs.map(Self.pageKey(from:))
        for key in keys {
            guard page.press(keyCode: key.code, characters: key.characters, ignoringModifiers: key.ignoringModifiers, modifiers: key.modifiers) else {
                throw ControlError("ページへキーを渡せなかった。")
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        // スクロールやタブの移動が画面に出るのを待つ。
        try? await Task.sleep(for: .milliseconds(300))
        return "sent \(specs.joined(separator: " "))\n" + store.allTabs.map(describe).joined(separator: "\n")
    }

    /// `page-key` のキー。`key` と同じ書き方に、大文字（Shift つきの英字）を加える。
    private static func pageKey(from spec: String) throws -> (code: UInt16, characters: String, ignoringModifiers: String, modifiers: NSEvent.ModifierFlags) {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard var name = parts.popLast(), !name.isEmpty else { throw ControlError("キーがない: \(spec)") }
        var modifiers = try Self.modifiers(from: parts.map { $0.lowercased() })
        if name.count == 1, let letter = name.first, letter.isUppercase, letter.isASCII {
            modifiers.insert(.shift)
            name = name.lowercased()
        }
        name = name.lowercased()
        guard let (code, base) = keys[name] else {
            let named = keys.keys.filter { letterKeys[$0] == nil }.sorted()
            throw ControlError("知らないキー: \(name)（a〜z、A〜Z, \(named.joined(separator: ", "))）")
        }
        let characters = modifiers.contains(.shift) && letterKeys[name] != nil ? base.uppercased() : base
        return (code, characters, base, modifiers)
    }

    private static func modifiers(from names: [String]) throws -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name {
            case "cmd": flags.insert(.command)
            case "ctrl": flags.insert(.control)
            case "opt", "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: throw ControlError("知らない修飾キー: \(name)（cmd, ctrl, opt, shift）")
            }
        }
        return flags
    }

    /// 式ならその値を、文の並びなら `return` した値を、JSONにして返す。`frame` が nil なら主フレームで走らせる。
    private func evaluate(_ code: String, on tab: Tab, in frame: WKFrameInfo?) async throws -> String {
        let finish = "return JSON.stringify(__value === undefined ? null : __value);"
        let asExpression = "const __value = await (\(code)\n); \(finish)"
        let asStatements = "const __value = await (async () => {\(code)\n})(); \(finish)"
        do {
            return try await script(asExpression, on: tab, in: frame, world: .page)
        } catch where Self.describe(error).contains("SyntaxError") {
            return try await script(asStatements, on: tab, in: frame, world: .page)
        }
    }

    private func screenshot(of tab: Tab, to path: String?, fullPage: Bool) async throws -> String {
        guard let page = tab.page else { throw ControlError("このタブにはまだページがない。") }
        guard tab.id == store.selectedID else {
            throw ControlError("画面に出ているタブしか撮れない。先に `select \(tab.number)` を行うこと。")
        }
        let data = try await page.snapshot(fullPage: fullPage)
        let destination = URL(filePath: path ?? NSTemporaryDirectory() + "hane-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: destination)
        return destination.path(percentEncoded: false)
    }

    /// 窓の中身をアプリ自身に描かせて画像にする。画面収録の権限が要らず、窓が裏にいても撮れる。
    ///
    /// `cacheDisplay` で描かせるとバーの背景が明るい外観の白で塗られて実物と違ってしまうので、
    /// Core Animation の層をそのまま描く。窓の背景の素材は中身の外にあって写らないので、
    /// 外観に合わせた窓の背景色を下に敷く。
    private func windowScreenshot(to path: String?) throws -> String {
        guard let window = mainWindow(), let view = window.contentView, let layer = view.layer else {
            throw ControlError("窓が出ていない。")
        }
        view.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ControlError("窓を画像にできなかった。")
        }
        let cg = context.cgContext
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            // 外観で変わる色は、外観を当てた中で具体的な色に直さないと明るい外観の色になる。
            cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            cg.scaleBy(x: scale, y: scale)
            if view.isFlipped {
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
            }
            layer.render(in: cg)
        }
        bitmap.size = size

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ControlError("窓を画像にできなかった。")
        }
        let destination = URL(filePath: path ?? NSTemporaryDirectory() + "hane-window-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: destination)
        let appearance = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        return destination.path(percentEncoded: false) + "\nappearance: \(appearance)"
    }

    private func script(
        _ body: String,
        _ arguments: [String: Any] = [:],
        on tab: Tab,
        in frame: WKFrameInfo? = nil,
        world: WKContentWorld? = nil
    ) async throws -> String {
        try await scriptValue(body, arguments, on: tab, in: frame, world: world) as? String ?? ""
    }

    /// スクリプトが返した値をそのまま返す。`frame` が nil なら主フレームで走らせる。
    private func scriptValue(
        _ body: String,
        _ arguments: [String: Any] = [:],
        on tab: Tab,
        in frame: WKFrameInfo? = nil,
        world: WKContentWorld? = nil
    ) async throws -> Any? {
        guard let page = tab.page else { throw ControlError("このタブにはまだページがない。先に `open <URL>` を行うこと。") }
        return try await page.callJavaScript(body, arguments: arguments, in: frame, contentWorld: world ?? self.world)
    }

    /// 読み込みが終わるのを待ってから、タブの状態を返す。
    private func settled(_ tab: Tab) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.loadTimeout
        // 操作から読み込み開始までに少し間があるので、先に一拍おく。
        try? await Task.sleep(for: .milliseconds(250))
        while tab.isLoading, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !tab.isLoading { await awaitTitle(of: tab) }
        if let failure = tab.failure {
            throw ControlError("読み込みに失敗: \(failure)\n" + describe(tab))
        }
        return describe(tab) + (tab.isLoading ? "\n（まだ読み込み中。`wait` で続きを待てる）" : "")
    }

    /// 尋ねたページの題名の置き場。返りを待たずにシートを見張るため、別の仕事から書き込む。
    @MainActor
    private final class TitleProbe {
        var done = false
        var title: String?
    }

    /// 読み終えたページの題名が、アプリ（`Page.title`）に届くまで待つ。
    ///
    /// WebKit は読み終えた知らせ（`isLoading` が偽になる）の数ミリ秒後に題名を知らせることがあり、
    /// その間に返ると題名の欠けた状態を返してしまう。題名のないページもあるので、題名が届くのを待つだけでは
    /// 終わりが分からない。そこでページに `document.title` を尋ね、それがアプリに届くまで待つ。
    /// アラートのシートが出るとスクリプトが返らないので、返りを直に待たずにシートを見張る（`waitFor` と同じ）。
    private func awaitTitle(of tab: Tab) async {
        guard let page = tab.page else { return }
        let probe = TitleProbe()
        Task { @MainActor [world] in
            probe.title = try? await page.callJavaScript("return document.title", arguments: [:], contentWorld: world) as? String
            probe.done = true
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline, !tab.isLoading, tab.page === page {
            if let sheet = model.currentWindow?.attachedSheet, sheet.isVisible { return }
            if probe.done, (probe.title ?? "").isEmpty || page.title == probe.title { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: アプリ自身の記録

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

    // MARK: 条件を待つ

    /// `wait` で待つ条件。決めたものすべてが成り立つまで（`gone` ならどれも成り立たなくなるまで）待つ。
    private struct WaitConditions {
        let text: String?
        let selector: String?
        let script: String?
        let gone: Bool

        var isEmpty: Bool { text == nil && selector == nil && script == nil }
    }

    /// 確かめの結果。`detail` は、足りなかったものを理由に書くための今の様子。
    private struct WaitReport {
        let met: Bool
        let detail: String
    }

    /// 確かめを別の仕事として走らせている間の結果の置き場。
    ///
    /// アラートのシートが出るとページのスクリプトは返らなくなるので、待つ側は確かめの返りを待たずに
    /// シートと時間切れを見張る。返らないまま置き去りにした確かめは、シートに答えれば自然に終わる。
    @MainActor
    private final class WaitPoll {
        var running = false
        var report: WaitReport?
    }

    /// 命令の間だけ、短い間隔でページに尋ねて、条件が成り立つまで待つ。
    ///
    /// 常駐の見張りを足さないよう、普段の閲覧には何も掛けず、尋ねるのはこの命令の間だけにしている。
    /// 読み込みが始まったら（ページが移ったら）終わるまで待ち、移った先で確かめ続ける。
    private func waitFor(_ conditions: WaitConditions, in path: [Int]?, timeout: Double, on tab: Tab) async throws -> String {
        guard tab.page != nil else { throw ControlError("このタブにはまだページがない。先に `open <URL>` を行うこと。") }
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started + .seconds(timeout)
        let poll = WaitPoll()
        var last = "（まだ確かめられていない）"
        while true {
            if let sheet = model.currentWindow?.attachedSheet, sheet.isVisible {
                throw ControlError("アラートのシートが出ていて、ページのスクリプトが止まっている。"
                    + "先に ui-snapshot と ui-click か key return で答えること。\n最後に見えた状態: \(last)")
            }
            // 確かめている間に読み込みが始まっていたら、移る前のページの結果なので捨てる。
            if let report = poll.report {
                poll.report = nil
                if !tab.isLoading {
                    last = report.detail
                    if report.met {
                        let elapsed = clock.now - started
                        return describe(tab) + "\nwait: 条件が成り立った（\(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))) 後）\n" + last
                    }
                }
            }
            if !tab.isLoading, let failure = tab.failure {
                throw ControlError("読み込みに失敗: \(failure)\n" + describe(tab))
            }
            if clock.now >= deadline {
                throw ControlError("条件が成り立たないまま \(timeout) 秒たった。\n最後に見えた状態: \(last)"
                    + (poll.running ? "（確かめのスクリプトが返っていない）" : "")
                    + (tab.isLoading ? "\n（まだ読み込み中）" : "") + "\n" + describe(tab))
            }
            if !tab.isLoading, !poll.running {
                poll.running = true
                Task { @MainActor in
                    poll.report = await checkWait(conditions, in: path, on: tab)
                    poll.running = false
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 条件をページで一度確かめる。ページが移っている最中などで尋ねられなければ、成り立っていないものとする。
    private func checkWait(_ conditions: WaitConditions, in path: [Int]?, on tab: Tab) async -> WaitReport {
        var results: [(present: Bool, label: String)] = []
        do {
            let frame = try await frame(at: path ?? [], on: tab)
            if conditions.text != nil || conditions.selector != nil {
                let value = try await scriptValue(
                    PageScripts.waitCondition,
                    ["text": conditions.text ?? NSNull(), "selector": conditions.selector ?? NSNull()],
                    on: tab, in: frame.info) as? [String: Any]
                if let text = conditions.text, let present = value?["text"] as? Bool {
                    results.append((present, "text \"\(text)\": " + (present ? "ある" : "ない")))
                }
                if let selector = conditions.selector, let count = value?["selector"] as? Int {
                    results.append((count > 0, "selector \(selector): 見えている要素 \(count) 個"))
                }
            }
            if let code = conditions.script {
                let json = try await evaluate(code, on: tab, in: frame.info)
                let truthy = !["null", "false", "0", "\"\""].contains(json)
                results.append((truthy, "js: \(json)"))
            }
        } catch {
            return WaitReport(met: false, detail: "（尋ねられなかった: \(Self.describe(error))）")
        }
        let met = conditions.gone ? results.allSatisfy { !$0.present } : results.allSatisfy(\.present)
        let label = conditions.gone ? "消えるのを待っている: " : ""
        return WaitReport(met: met, detail: label + results.map(\.label).joined(separator: "; "))
    }

    // MARK: 広告ブロック

    private func contentBlocker() throws -> ContentBlocker {
        guard let blocker = store.contentBlocker else { throw ControlError("広告ブロックが付いていない。") }
        return blocker
    }

    private func site(of tab: Tab) throws -> String {
        guard let site = tab.url.flatMap(HiddenElementStore.site(for:)) else {
            throw ControlError("このページでは要素を隠せない（http(s) か file のページのみ）。")
        }
        return site
    }

    private func describeAdBlock(_ blocker: ContentBlocker) -> String {
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
        if let tab = store.selected, let site = tab.url.flatMap(HiddenElementStore.site(for:)) {
            let selectors = blocker.hidden.selectors(on: site)
            lines.append("this site: \(site) (\(selectors.count))")
            lines += selectors.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    /// ダウンロードの一覧。始まった順。
    private func describeDownloads() -> String {
        let downloads = store.downloads
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

    /// プロファイルの一覧。今のもの（外部操作の相手）に *、ほかの窓に出ているものに + を付ける。
    private func describeProfiles() -> String {
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

    /// ウインドウの枠まわり（ページの外側）が今どう見えているか。
    private func describeUI() -> String {
        var lines = ["instance: \(BrowserInstance.label), profile: \(model.current)", describeBuild(), "window frame: " + describeWindowFrame()]
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
        lines.append("bookmarks bar: " + describeBookmarkBar())
        if let open = store.openFolder, let folder = store.bookmarks.folder(open.id) {
            // 選択の当たっている行に > を付ける。番号は数字キーで開くときのもの。
            let rows = folder.bookmarks.enumerated().map { index, bookmark in
                "[" + (index == open.highlighted ? ">" : "") + "\(index + 1) \(bookmark.title)]"
            }
            lines.append("folder list: \(folder.name) " + (rows.isEmpty ? "(空)" : rows.joined(separator: " ")))
        }
        for (_, kind) in WindowElements.windows(main: model.currentWindow).dropFirst() {
            lines.append("overlay: \(kind)（中身は ui-snapshot）")
        }
        lines.append("tabs (left to right):")
        lines.append(contentsOf: store.allTabs.map(describe))
        return lines.joined(separator: "\n")
    }

    /// 動いている実体と、その実行ファイルがいつ作られたか。
    ///
    /// 作り直したのに古い実体が動き続けていて（シートが出ていて終われなかったなど）、
    /// 古い版を確かめていたことがあった。起動のあとに作り直されていればそう書く。
    private func describeBuild() -> String {
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

    /// 窓の大きさと位置、覚えている名前。窓の枠を戻す仕組みが効いているかを外から確かめるため。
    /// 位置は画面の左上からの距離で表す（AppKit の座標は左下から測るので向きを直す）。
    private func describeWindowFrame() -> String {
        guard let window = mainWindow() else { return "(なし)" }
        let frame = window.frame
        let screen = window.screen?.frame ?? .zero
        let name = window.frameAutosaveName.isEmpty ? "(覚えない)" : "\"\(window.frameAutosaveName)\""
        return "\(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.minX - screen.minX)), \(Int(screen.maxY - frame.maxY)))"
            + " on \(Int(screen.width))x\(Int(screen.height)) screen, remembered as \(name)"
    }

    /// バーの左側を、画面に出ている文字のとおりに一行で表す。
    /// 選ばれている項目には *、ページを開いている項目には (open) を付ける。
    private func describeBookmarkBar() -> String {
        guard !store.bookmarks.items.isEmpty else { return "(なし)" }
        return store.bookmarks.items.map { item in
            switch item {
            case .bookmark(let bookmark):
                let tab = store.bookmarkTabs[bookmark.id]
                let label = store.awayTitle(for: bookmark).map { "\(bookmark.title) / \($0)" } ?? bookmark.title
                return "[" + mark(tab) + label + (tab != nil ? " (open)" : "") + "]"
            case .folder(let folder):
                let selected = folder.bookmarks.first { store.bookmarkTabs[$0.id]?.id == store.selectedID }
                let label = selected.map { "\(folder.name) › \(store.awayTitle(for: $0) ?? $0.title)" } ?? folder.name
                return "[" + (selected != nil ? "*" : "") + label + " ▾]"
            }
        }.joined(separator: " ")
    }

    /// ページの外（メニューやバー）へ、利用者が打ったのと同じ道筋でキーを送る。
    ///
    /// 本物のキーが通る順（局所モニタ、窓の部品のキー、メニュー、ウインドウ）をここで辿って手渡しする。
    /// 裏にいるとキーを受けるウインドウがなく、自分から前に出ることもシステムに断られるため。
    /// 前面にいるときも同じ道を通す。待ち行列に積むと、アラートの Return と Esc が効かなかった。
    private func sendKey(_ spec: String) throws {
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.popLast() else { throw ControlError("キーがない。") }
        let flags = try Self.modifiers(from: parts)
        guard let (keyCode, characters) = Self.keys[name] else {
            let named = Self.keys.keys.filter { Self.letterKeys[$0] == nil }.sorted()
            throw ControlError("知らないキー: \(name)（a〜z, \(named.joined(separator: ", "))）")
        }
        guard let window = NSApp.keyWindow ?? backgroundKeyTarget() else {
            throw ControlError("ウインドウがない。")
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { throw ControlError("キーの事象を作れない: \(spec)") }

        if LocalShortcuts.handle(event, model: model) { return }
        // 離す事象がないと、ページの文字のキーでの操作（KeyNavigation）が押しっぱなしとみなしてスクロールを流し続ける。
        // 修飾なしの文字は Web ビューが performKeyEquivalent で拾ってページへ渡すので、どの道でも最後に離す。
        // 押す事象と同じく待ち行列に積まず直に渡す。
        defer {
            if let release = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ) { window.sendEvent(release) }
        }
        // メニューより先に窓の部品へ渡す。アラートや編集欄の既定のボタン（Return）とキャンセル（Esc）はここで拾われる。
        if window.performKeyEquivalent(with: event) { return }
        // 既定のボタン（アラートの OK など）の Return は、窓がキーを受ける窓のときしか効かない。裏にいるアプリの窓は
        // キーを受ける窓になれないので、裏ではシートが Return で閉じなかった（Esc のような、ボタン自身に割り当てたキーは効く）。
        // 前で打ったときと同じく、既定のボタンを押す。
        if !window.isKeyWindow, flags.isEmpty, characters == "\r", let button = window.defaultButtonCell {
            button.performClick(nil)
            return
        }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        window.sendEvent(event)
    }

    /// フォーカスのある入力欄へ、1文字ずつ打ち込んだのと同じように差し込む。
    ///
    /// キーの事象を作って送ると、持ち主の入力方式が日本語のときに仮名へ変換されてしまうので、
    /// 入力欄の編集部品（フィールドエディタ）へ文字を直接入れる。文字ごとに間を置き、
    /// 画面が1文字ずつ変化を受け取れるようにする。
    private func typeText(_ text: String, replacing: Bool) async throws {
        let window = NSApp.keyWindow ?? backgroundKeyTarget()
        if replacing {
            guard let editor = window?.firstResponder as? NSTextView else {
                throw ControlError("文字を受け付ける入力欄にフォーカスがない。")
            }
            editor.selectAll(nil)
        }
        for character in text {
            guard let editor = window?.firstResponder as? NSTextView else {
                throw ControlError("文字を受け付ける入力欄にフォーカスがない。")
            }
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// 裏にいるとき、前に出ていればキーを受けたはずのウインドウ。シートやポップオーバーが出ていればそちら。
    private func backgroundKeyTarget() -> NSWindow? {
        WindowElements.windows(main: model.currentWindow).last?.window
    }

    private func mainWindow() -> NSWindow? {
        WindowElements.windows(main: model.currentWindow).first?.window
    }

    /// 窓まわりを操作したあと、画面の更新とポップオーバーの出し入れを待ってから様子を添えて返す。
    private func afterUIAction(_ result: String) async -> String {
        try? await Task.sleep(for: .milliseconds(300))
        return result + "\n" + describeUI()
    }

    /// `key` で送れるキー。値は仮想キーコードと、そのキーが打ち出す文字。
    private static let keys: [String: (UInt16, String)] = [
        "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "5": (23, "5"),
        "6": (22, "6"), "7": (26, "7"), "8": (28, "8"), "9": (25, "9"),
        "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
        "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
        "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "return": (36, "\r"),
        "escape": (53, "\u{1b}"),
        "delete": (51, "\u{7f}"),
        "tab": (48, "\t"),
        "space": (49, " "),
        ",": (43, ","),
    ].merging(letterKeys) { $1 }

    /// 英字キー。仮想キーコードは並びが文字の順ではない（US 配列の位置で決まっている）。
    private static let letterKeys: [String: (UInt16, String)] = {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
            "k": 40, "n": 45, "m": 46,
        ]
        return Dictionary(uniqueKeysWithValues: codes.map { (String($0.key), ($0.value, String($0.key))) })
    }()

    /// ブックマークを番号つきで一覧する。番号はフォルダも含めた上からの通し番号。
    private func describeBookmarks() -> String {
        var lines: [String] = []
        var number = 0
        func line(_ bookmark: Bookmark, indent: String) -> String {
            number += 1
            let tab = store.bookmarkTabs[bookmark.id]
            let open = tab.map { " (open: tab \($0.number))" } ?? ""
            return "\(mark(tab).isEmpty ? " " : "*") \(indent)\(number) \(bookmark.title) — \(bookmark.url.absoluteString)\(open)"
        }
        for item in store.bookmarks.items {
            switch item {
            case .bookmark(let bookmark):
                lines.append(line(bookmark, indent: ""))
            case .folder(let folder):
                number += 1
                lines.append("  \(number) \(folder.name)/")
                lines.append(contentsOf: folder.bookmarks.map { line($0, indent: "  ") })
            }
        }
        return lines.isEmpty ? "（ブックマークなし）" : lines.joined(separator: "\n")
    }

    private func mark(_ tab: Tab?) -> String {
        tab != nil && tab?.id == store.selectedID ? "*" : ""
    }

    /// `bookmarks` の一覧に出る番号を、ブックマークかフォルダのIDに引き直す。
    private func bookmarkID(_ text: String) throws -> UUID {
        let number = try integer(text, "ブックマークの番号")
        let ids = store.bookmarks.items.flatMap { item -> [UUID] in
            switch item {
            case .bookmark(let bookmark): [bookmark.id]
            case .folder(let folder): [folder.id] + folder.bookmarks.map(\.id)
            }
        }
        guard ids.indices.contains(number - 1) else {
            throw ControlError("ブックマーク \(number) はない。`bookmarks` で一覧を見ること。")
        }
        return ids[number - 1]
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: 引数と表示

    private func tab(numbered number: Int?) throws -> Tab {
        guard let number else {
            guard let selected = store.selected else { throw ControlError("タブがない。") }
            return selected
        }
        guard let tab = store.allTabs.first(where: { $0.number == number }) else {
            throw ControlError("タブ \(number) はない。`tabs` で一覧を見ること。")
        }
        return tab
    }

    private func describe(_ tab: Tab) -> String {
        let mark = tab.id == store.selectedID ? "*" : " "
        let url = tab.url?.absoluteString ?? "(空)"
        let loading = tab.isLoading ? " [loading]" : tab.isAsleep ? " [asleep]" : ""
        let icon = tab.favicon != nil ? " [icon]" : ""
        let bookmark = store.bookmarkID(of: tab).flatMap(store.bookmarks.bookmark).map { " [bookmark: \($0.title)]" } ?? ""
        return "\(mark) tab \(tab.number): \(tab.title) — \(url)\(loading)\(icon)\(bookmark)"
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

    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return "JavaScriptエラー: \(message)"
        }
        return nsError.localizedDescription
    }
}

/// ページが出したメニュー（右クリックのメニューや選択欄の選択肢）を、出たそばから閉じて項目を控える。
///
/// 出たままだと持ち主の画面に残り、閉じるまでメインスレッドがメニューの中を回り続ける。
/// メニューの項目を選ぶ道は持たない（選択欄は fill で選べる）。
@MainActor
private final class MenuCatcher: NSObject {
    /// 出たメニューの項目。出なければ nil。
    private(set) var items: [String]?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(began), name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    /// メニューが回り始めたときに、メインスレッドで呼ばれる。
    @objc private func began(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        items = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
        // 回り始めの知らせの中で閉じても効かず、メニューは出たままになった。一拍おいてから閉じる。
        Task { @MainActor in menu.cancelTrackingWithoutAnimation() }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }
}

struct ControlError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
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
