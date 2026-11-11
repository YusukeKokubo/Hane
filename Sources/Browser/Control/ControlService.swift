import AppKit
import ControlWire
import Foundation
import WebKit

/// 外部からの操作要求を、タブとページへの操作に置き換える。
///
/// 命令の一覧と書式は `ControlHelp` の文面が正本。
@MainActor
final class ControlService {
    private let store: TabStore
    /// 要素の控えを置く実行環境。ページ自身のスクリプトからは見えない。
    private let world = WKContentWorld.world(name: "browserctl")

    private static let loadTimeout: Duration = .seconds(30)

    init(store: TabStore) {
        self.store = store
    }

    func start() {
        do {
            try ControlServer.start { [weak self] request in
                await self?.respond(to: request) ?? ControlResponse(ok: false, output: "アプリが終了中")
            }
        } catch {
            NSLog("操作用ソケットを開けませんでした: \(error)")
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
            guard store.allTabs.count > 1 || tab.bookmarkID != nil else {
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
            return try await settled(try target())

        case "snapshot":
            let tab = try target()
            let listing = try await script(PageScripts.snapshot, ["limit": limit ?? 300], on: tab)
            return describe(tab) + "\n" + listing

        case "text":
            let tab = try target()
            let body = try await script(PageScripts.text, ["limit": limit ?? 50_000], on: tab)
            return describe(tab) + "\n\n" + body

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

        case "eval":
            guard !args.isEmpty else { throw ControlError("JavaScriptがない。例: eval \"document.title\"") }
            return try await evaluate(args.joined(separator: " "), on: try target())

        case "ui":
            return describeUI()

        case "key":
            try sendKey(try argument(args, 0, "キー"))
            // 画面の更新とポップオーバーの出し入れを待ってから様子を返す。
            try? await Task.sleep(for: .milliseconds(300))
            return describeUI()

        case "type":
            guard !args.isEmpty else { throw ControlError("打つ文字列がない。例: type github") }
            try await typeText(args.joined(separator: " "))
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

        case "bookmark-add":
            let name = try takeOption("--name", from: &args)
            let folderName = try takeOption("--folder", from: &args)
            let folderID = folderName.map { store.bookmarks.folder(named: $0)?.id ?? store.bookmarks.addFolder(named: $0).id }
            if args.isEmpty {
                let tab = try target()
                guard tab.bookmarkID == nil else { throw ControlError("このタブはすでにブックマークのページ。") }
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

        case "stats":
            let seconds = try takeOption("--seconds", from: &args).map { text in
                guard let value = Double(text), (0.1...60).contains(value) else {
                    throw ControlError("--seconds は 0.1〜60 の数で指定すること: \(text)")
                }
                return value
            } ?? 0.5
            let json = takeFlag("--json", from: &args)
            let report = await ProcessStats.measure(for: .milliseconds(Int(seconds * 1000)))
            let all = store.allTabs
            let tabs = StatsTabs(total: all.count, withContent: all.count { $0.hasContent }, bookmarkPages: store.bookmarkTabs.count)
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(StatsOutput(report: report, tabs: tabs))
                return String(decoding: data, as: UTF8.self)
            }
            return ProcessStats.table(report)
                + "\ntabs: \(tabs.total)（うちページあり \(tabs.withContent)、ブックマークのページ \(tabs.bookmarkPages)）"

        case "quit":
            // 応答を返し終えてから終了する。
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.terminate(nil)
            }
            return "quitting"

        case "screenshot":
            return try await screenshot(of: try target(), to: args.first, fullPage: fullPage)

        case "window-screenshot":
            return try windowScreenshot(to: args.first)

        default:
            throw ControlError("未知の命令: \(command)。`browserctl help` で一覧を見ること。")
        }
    }

    // MARK: ページへの操作

    private func act(_ action: String, ref: Int, text: String, on tab: Tab) async throws -> String {
        // 以前の読み込み失敗が残っていると、この操作の結果と取り違える。
        tab.dismissFailure()
        let reply = try await script(PageScripts.act, ["ref": ref, "action": action, "text": text], on: tab)
        if let data = reply.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String {
            throw ControlError(message)
        }
        // クリックや送信でページが切り替わることがあるので、落ち着くまで待つ。
        return try await settled(tab)
    }

    /// 式ならその値を、文の並びなら `return` した値を、JSONにして返す。
    private func evaluate(_ code: String, on tab: Tab) async throws -> String {
        let finish = "return JSON.stringify(__value === undefined ? null : __value);"
        let asExpression = "const __value = await (\(code)\n); \(finish)"
        let asStatements = "const __value = await (async () => {\(code)\n})(); \(finish)"
        do {
            return try await script(asExpression, on: tab, world: .page)
        } catch where Self.describe(error).contains("SyntaxError") {
            return try await script(asStatements, on: tab, world: .page)
        }
    }

    private func screenshot(of tab: Tab, to path: String?, fullPage: Bool) async throws -> String {
        guard tab.hasContent else { throw ControlError("このタブにはまだページがない。") }
        guard tab.id == store.selectedID else {
            throw ControlError("画面に出ているタブしか撮れない。先に `select \(tab.number)` を行うこと。")
        }
        var region = WebPage.ExportedContentConfiguration.Region.contents
        if !fullPage {
            let reply = try await script(PageScripts.viewport, on: tab)
            if let data = reply.data(using: .utf8),
               let box = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
               let x = box["x"], let y = box["y"], let width = box["width"], let height = box["height"] {
                region = .rect(CGRect(x: x, y: y, width: width, height: height))
            }
        }
        let data = try await tab.page.exported(as: .image(region: region))
        let destination = URL(filePath: path ?? NSTemporaryDirectory() + "browser-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: destination)
        return destination.path(percentEncoded: false)
    }

    /// 窓の中身をアプリ自身に描かせて画像にする。画面収録の権限が要らず、窓が裏にいても撮れる。
    ///
    /// `cacheDisplay` で描かせるとバーの背景が明るい外観の白で塗られて実物と違ってしまうので、
    /// Core Animation の層をそのまま描く。窓の背景の素材は中身の外にあって写らないので、
    /// 外観に合わせた窓の背景色を下に敷く。
    private func windowScreenshot(to path: String?) throws -> String {
        guard let window = Self.backgroundKeyTarget(), let view = window.contentView, let layer = view.layer else {
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
        let destination = URL(filePath: path ?? NSTemporaryDirectory() + "browser-window-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: destination)
        let appearance = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        return destination.path(percentEncoded: false) + "\nappearance: \(appearance)"
    }

    private func script(
        _ body: String,
        _ arguments: [String: Any] = [:],
        on tab: Tab,
        world: WKContentWorld? = nil
    ) async throws -> String {
        guard tab.hasContent else { throw ControlError("このタブにはまだページがない。先に `open <URL>` を行うこと。") }
        let value = try await tab.page.callJavaScript(body, arguments: arguments, contentWorld: world ?? self.world)
        return value as? String ?? ""
    }

    /// 読み込みが終わるのを待ってから、タブの状態を返す。
    private func settled(_ tab: Tab) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.loadTimeout
        // 操作から読み込み開始までに少し間があるので、先に一拍おく。
        try? await Task.sleep(for: .milliseconds(250))
        while tab.page.isLoading, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let failure = tab.failure {
            throw ControlError("読み込みに失敗: \(failure)\n" + describe(tab))
        }
        return describe(tab) + (tab.page.isLoading ? "\n（まだ読み込み中。`wait` で続きを待てる）" : "")
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

    /// ウインドウの枠まわり（ページの外側）が今どう見えているか。
    private func describeUI() -> String {
        var lines = ["profile: \(BrowserProfile.name)", "window frame: " + describeWindowFrame()]
        if let tab = store.selected {
            let state: (Bool) -> String = { $0 ? "enabled" : "disabled" }
            lines.append("window title: \(tab.title)")
            lines.append("address bar: \"\(store.addressBar.text)\"" + (store.addressBar.isFocused ? " (focused)" : "")
                + (store.addressBar.completion.map { " completion=\"\($0)\"" } ?? ""))
            lines.append("buttons: back=\(state(tab.canGoBack)) forward=\(state(tab.canGoForward)) "
                + (tab.page.isLoading ? "stop=enabled" : "reload=\(state(tab.hasContent))"))
            lines.append("page: " + (tab.hasContent
                ? (tab.page.isLoading ? "loading \(Int(tab.page.estimatedProgress * 100))%" : "loaded")
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
        lines.append("tabs (left to right):")
        lines.append(contentsOf: store.allTabs.map(describe))
        return lines.joined(separator: "\n")
    }

    /// 窓の大きさと位置、覚えている名前。窓の枠を戻す仕組みが効いているかを外から確かめるため。
    /// 位置は画面の左上からの距離で表す（AppKit の座標は左下から測るので向きを直す）。
    private func describeWindowFrame() -> String {
        guard let window = Self.backgroundKeyTarget() else { return "(なし)" }
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
    /// 前面にいれば事象の待ち行列に積み、局所モニタ、メニュー、ウインドウの順に本物のキーと同じく渡す。
    /// 裏にいるとキーを受けるウインドウがなく、自分から前に出ることもシステムに断られる。
    /// 動作確認のたびに持ち主の作業を遮らないよう、そのときは同じ順をここで辿って手渡しする。
    private func sendKey(_ spec: String) throws {
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.popLast() else { throw ControlError("キーがない。") }
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts {
            switch modifier {
            case "cmd": flags.insert(.command)
            case "ctrl": flags.insert(.control)
            case "opt", "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: throw ControlError("知らない修飾キー: \(modifier)（cmd, ctrl, opt, shift）")
            }
        }
        guard let (keyCode, characters) = Self.keys[name] else {
            throw ControlError("知らないキー: \(name)（\(Self.keys.keys.sorted().joined(separator: ", "))）")
        }
        let isActive = NSApp.isActive && NSApp.keyWindow != nil
        guard let window = isActive ? NSApp.keyWindow : Self.backgroundKeyTarget() else {
            throw ControlError("ウインドウがない。")
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { throw ControlError("キーの事象を作れない: \(spec)") }

        if isActive {
            NSApp.postEvent(event, atStart: false)
            return
        }
        if FolderShortcut.handle(event, store: store) { return }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        window.sendEvent(event)
    }

    /// フォーカスのある入力欄へ、1文字ずつ打ち込んだのと同じように差し込む。
    ///
    /// キーの事象を作って送ると、持ち主の入力方式が日本語のときに仮名へ変換されてしまうので、
    /// 入力欄の編集部品（フィールドエディタ）へ文字を直接入れる。文字ごとに間を置き、
    /// 画面が1文字ずつ変化を受け取れるようにする。
    private func typeText(_ text: String) async throws {
        let window = NSApp.keyWindow ?? Self.backgroundKeyTarget()
        for character in text {
            guard let editor = window?.firstResponder as? NSTextView else {
                throw ControlError("文字を受け付ける入力欄にフォーカスがない。")
            }
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// 裏にいるとき、前に出ていればキーを受けたはずのウインドウ。ポップオーバーが出ていればそちら。
    private static func backgroundKeyTarget() -> NSWindow? {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return nil }
        return main.childWindows?.last(where: \.isVisible) ?? main
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
    ]

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
        let loading = tab.page.isLoading ? " [loading]" : tab.isWaitingToLoad ? " [not loaded]" : ""
        let bookmark = tab.bookmarkID.flatMap(store.bookmarks.bookmark).map { " [bookmark: \($0.title)]" } ?? ""
        return "\(mark) tab \(tab.number): \(tab.title) — \(url)\(loading)\(bookmark)"
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
    let bookmarkPages: Int
}
