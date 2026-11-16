import Foundation
import WebKit

/// ページの中を読み、操作する。`hanectl` の実行環境でスクリプトを走らせ、iframe の中へも下りる。
///
/// タブとページだけを相手にし、窓やモデルは知らない。答えの頭に付けるタブの行と、アラートのシートが
/// 出ているか（出ているとページのスクリプトが返らない）は、振り分ける側から受け取る。
@MainActor
final class PageScripting {
    /// 要素の控えを置く実行環境。ページ自身のスクリプトからは見えない。
    /// 子フレームの窓をアプリへ渡せる（`createJSHandle`）ようにして、iframe の中でも走らせられるようにしてある。
    /// 設定から作った実行環境は名前で引き直せないので、持ち続ける。
    /// ページへの命令が初めて来たときに作る。外から操作しない普段の起動では、この口に触れない。
    private lazy var world: WKContentWorld = {
        // 子フレームを引く公開の口は macOS 27 の `WKJSHandle` が初めてで、26 では iframe の中へは下りない。
        // 下りないぶんは名前で引く実行環境で足りる。
        guard #available(macOS 27, *) else { return .world(name: "hanectl") }
        let configuration = WKContentWorld.Configuration()
        configuration.jsHandleCreationEnabled = true
        return WKContentWorld(configuration: configuration)
    }()

    /// iframe の中へ下りられるか（macOS 27 から）。
    nonisolated static var canEnterFrames: Bool {
        if #available(macOS 27, *) { true } else { false }
    }
    /// タブの状態を一行で表す。
    private let describe: @MainActor (Tab) -> String
    /// アラートのシートが出ているか。
    private let sheetIsShown: @MainActor () -> Bool

    private static let loadTimeout: Duration = .seconds(30)

    init(describe: @escaping @MainActor (Tab) -> String, sheetIsShown: @escaping @MainActor () -> Bool) {
        self.describe = describe
        self.sheetIsShown = sheetIsShown
    }

    // MARK: 命令

    /// 操作できる要素の一覧を、タブの行に続けて返す。
    func snapshot(of tab: Tab, limit: Int) async throws -> String {
        describe(tab) + "\n" + (try await listing(of: tab, limit: limit))
    }

    /// 本文の文字。`path` を渡せばその子フレームの。
    func text(of tab: Tab, in path: [Int]?, limit: Int) async throws -> String {
        let frame = try await frame(at: path ?? [], on: tab)
        let body = try await script(PageScripts.text, ["limit": limit], on: tab, in: frame.info)
        return describe(tab) + (path.map { "\n" + Self.describeFrame(path: $0, frame.info) } ?? "") + "\n\n" + body
    }

    /// ページの環境で JavaScript を走らせ、値を JSON にして返す。`path` を渡せばその子フレームで。
    func eval(_ code: String, in path: [Int]?, on tab: Tab) async throws -> String {
        let frame = try await frame(at: path ?? [], on: tab)
        return try await evaluate(code, on: tab, in: frame.info)
    }

    func act(_ action: String, ref: Int, text: String, on tab: Tab) async throws -> String {
        // 以前の読み込み失敗が残っていると、この操作の結果と取り違える。
        tab.dismissFailure()
        let (reply, _) = try await scriptFollowingFrames(PageScripts.act, ["ref": ref, "action": action, "text": text], on: tab)
        if let message = reply["error"] as? String {
            throw ControlError(message)
        }
        // クリックや送信でページが切り替わることがあるので、落ち着くまで待つ。
        return try await settled(tab)
    }

    /// セレクタに合う要素を、ページの上で隠す。隠した数を返す。
    func hide(_ selector: String, on tab: Tab) async throws -> Int {
        let reply = try await script(PageScripts.hide, ["selector": selector], on: tab)
        let object = reply.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let message = object?["error"] as? String { throw ControlError(message) }
        return object?["count"] as? Int ?? 0
    }

    // MARK: iframe の中

    /// 子フレームの中を読んだり操作したりするための、フレームとその位置。`info` が nil なら主フレーム。
    struct Frame {
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
    func frame(at path: [Int], from start: Frame = Frame(), on tab: Tab, reveal: Bool = false, every: Bool = false) async throws -> Frame {
        var frame = start
        guard path.isEmpty || Self.canEnterFrames else {
            throw ControlError("iframe の中へ下りるのは macOS 27 から。")
        }
        for index in path {
            let value = try await scriptValue(PageScripts.frame, ["index": index, "reveal": reveal, "every": every], on: tab, in: frame.info)
            guard let object = value as? [String: Any] else { throw ControlError("フレームを引けなかった。") }
            if let message = object["error"] as? String { throw ControlError(message) }
            guard #available(macOS 27, *), let handle = object["handle"] as? WKJSHandle, let info = await handle.windowProxyFrame else {
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
    private func listing(of tab: Tab, limit: Int) async throws -> String {
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
                let reason = (error as? ControlError)?.message ?? ControlError.describe(error)
                listing.lines.append(header + "（中を読めなかった: \(reason)）")
            }
        }
    }

    /// `snapshot` に出るフレームの名前（frame 1、frame 1.2 など）。
    static func frameLabel(_ path: [Int]) -> String {
        "frame " + path.map { String($0 + 1) }.joined(separator: ".")
    }

    private static func describeFrame(path: [Int], _ info: WKFrameInfo?) -> String {
        frameLabel(path) + (info?.request.url.map { " — " + $0.absoluteString } ?? "")
    }

    /// `--frame 1.2` を子フレームの順番の並びにする。
    static func framePath(_ text: String) throws -> [Int] {
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ ($0 ?? 0) > 0 }) else {
            throw ControlError("--frame は snapshot に出るフレームの番号（1 や 1.2）で指すこと: \(text)")
        }
        return numbers.map { $0! - 1 }
    }

    // MARK: 位置を測る

    /// `snapshot` の番号か `x,y`（CSS の画素。表示している範囲の左上から）で指された位置と、そこで事象を受ける要素。
    /// 番号の要素が画面の外なら、真ん中へスクロールしてから位置を測る。
    func locate(_ reference: String, on tab: Tab) async throws -> (point: CGPoint, target: String) {
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

    // MARK: スクリプトを走らせる

    /// 式ならその値を、文の並びなら `return` した値を、JSONにして返す。`frame` が nil なら主フレームで走らせる。
    private func evaluate(_ code: String, on tab: Tab, in frame: WKFrameInfo?) async throws -> String {
        let finish = "return JSON.stringify(__value === undefined ? null : __value);"
        let asExpression = "const __value = await (\(code)\n); \(finish)"
        let asStatements = "const __value = await (async () => {\(code)\n})(); \(finish)"
        do {
            return try await script(asExpression, on: tab, in: frame, world: .page)
        } catch where ControlError.describe(error).contains("SyntaxError") {
            return try await script(asStatements, on: tab, in: frame, world: .page)
        }
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
    func scriptValue(
        _ body: String,
        _ arguments: [String: Any] = [:],
        on tab: Tab,
        in frame: WKFrameInfo? = nil,
        world: WKContentWorld? = nil
    ) async throws -> Any? {
        guard let page = tab.page else { throw ControlError("このタブにはまだページがない。先に `open <URL>` を行うこと。") }
        return try await page.callJavaScript(body, arguments: arguments, in: frame, contentWorld: world ?? self.world)
    }

    // MARK: 読み込みを待つ

    /// 読み込みが終わるのを待ってから、タブの状態を返す。
    func settled(_ tab: Tab) async throws -> String {
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
            if sheetIsShown() { return }
            if probe.done, (probe.title ?? "").isEmpty || page.title == probe.title { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: 条件を待つ

    /// `wait` で待つ条件。決めたものすべてが成り立つまで（`gone` ならどれも成り立たなくなるまで）待つ。
    struct WaitConditions {
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
    func waitFor(_ conditions: WaitConditions, in path: [Int]?, timeout: Double, on tab: Tab) async throws -> String {
        guard tab.page != nil else { throw ControlError("このタブにはまだページがない。先に `open <URL>` を行うこと。") }
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started + .seconds(timeout)
        let poll = WaitPoll()
        var last = "（まだ確かめられていない）"
        while true {
            if sheetIsShown() {
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
            return WaitReport(met: false, detail: "（尋ねられなかった: \(ControlError.describe(error))）")
        }
        let met = conditions.gone ? results.allSatisfy { !$0.present } : results.allSatisfy(\.present)
        let label = conditions.gone ? "消えるのを待っている: " : ""
        return WaitReport(met: met, detail: label + results.map(\.label).joined(separator: "; "))
    }
}
