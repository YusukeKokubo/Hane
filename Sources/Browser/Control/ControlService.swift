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
            return store.tabs.map(describe).joined(separator: "\n")

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
            guard store.tabs.count > 1 else {
                throw ControlError("最後の1枚は閉じられない（ウインドウが閉じてアプリが終了するため）。")
            }
            store.close(tab.id)
            return "closed tab \(tab.number)\n" + store.tabs.map(describe).joined(separator: "\n")

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

        case "logs":
            let tab = try target()
            let entries = tab.log.entries.suffix(limit ?? 50)
            let listing = entries.isEmpty
                ? "（記録なし）"
                : entries.map { "\(Self.clock.string(from: $0.date)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
            if clear { tab.log.clear() }
            return describe(tab) + "\n" + listing

        case "stats":
            return await ProcessStats.report() + "\ntabs: \(store.tabs.count)（うちページあり \(store.tabs.count { $0.hasContent })）"

        case "quit":
            // 応答を返し終えてから終了する。
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.terminate(nil)
            }
            return "quitting"

        case "screenshot":
            return try await screenshot(of: try target(), to: args.first, fullPage: fullPage)

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

    /// ウインドウの枠まわり（ページの外側）が今どう見えているか。
    private func describeUI() -> String {
        var lines = ["profile: \(BrowserProfile.name)"]
        if let tab = store.selected {
            let state: (Bool) -> String = { $0 ? "enabled" : "disabled" }
            lines.append("window title: \(tab.title)")
            lines.append("address bar: \"\(store.addressBar.text)\"" + (store.addressBar.isFocused ? " (focused)" : ""))
            lines.append("buttons: back=\(state(tab.canGoBack)) forward=\(state(tab.canGoForward)) "
                + (tab.page.isLoading ? "stop=enabled" : "reload=\(state(tab.hasContent))"))
            lines.append("page: " + (tab.hasContent
                ? (tab.page.isLoading ? "loading \(Int(tab.page.estimatedProgress * 100))%" : "loaded")
                : "empty"))
            if let failure = tab.failure {
                lines.append("failure shown: \(failure)")
            }
        }
        lines.append("tabs (left to right):")
        lines.append(contentsOf: store.tabs.map(describe))
        return lines.joined(separator: "\n")
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
        guard let tab = store.tabs.first(where: { $0.number == number }) else {
            throw ControlError("タブ \(number) はない。`tabs` で一覧を見ること。")
        }
        return tab
    }

    private func describe(_ tab: Tab) -> String {
        let mark = tab.id == store.selectedID ? "*" : " "
        let url = tab.page.url?.absoluteString ?? "(空)"
        let loading = tab.page.isLoading ? " [loading]" : ""
        return "\(mark) tab \(tab.number): \(tab.title) — \(url)\(loading)"
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
