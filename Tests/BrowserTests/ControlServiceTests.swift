import ControlWire
import Foundation
import Testing
@testable import Browser

/// 操作用の命令を、ソケットを介さずに直接呼んで確かめる。
@MainActor
@Suite struct ControlServiceTests {
    private let store: TabStore
    private let service: ControlService

    init() {
        store = TabStore(factory: PageFactory(dataStore: .nonPersistent()))
        service = ControlService(store: store)
    }

    private func run(_ args: String...) async -> ControlResponse {
        await service.respond(to: ControlRequest(args: args))
    }

    /// HTMLを一時ファイルに書いて開く。ネットワークには出ない。
    private func open(html: String) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "control-test-\(UUID().uuidString).html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        let response = await run("open", file.absoluteString)
        try #require(response.ok, "\(response.output)")
    }

    private static let form = """
    <title>Form</title><h1>Sign in</h1>
    <label>Name <input id="name"></label>
    <select id="color"><option>Red</option><option>Blue</option></select>
    <button onclick="document.title = 'clicked ' + document.getElementById('name').value">Go</button>
    <input type="hidden" name="secret"><a href="#next">Next</a>
    """

    /// 前回の閲覧から戻しただけのタブは一覧で分かり、reload で読み込める。
    @Test func restoredTabsWaitUntilAsked() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "control-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "session.json")
        let waiting = directory.appending(path: "waiting.html")
        SessionStore(fileURL: file).save(SavedSession(
            pages: [SavedPage(url: directory.appending(path: "shown.html"), title: "Shown"), SavedPage(url: waiting, title: "Waiting")],
            selected: 0
        ))
        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()), session: SessionStore(fileURL: file))
        let service = ControlService(store: store)

        let listing = await service.respond(to: ControlRequest(args: ["tabs"])).output
        #expect(listing.contains("tab 2: Waiting — \(waiting.absoluteString) [not loaded]"))
        #expect(!listing.contains("Shown — \(directory.appending(path: "shown.html").absoluteString) [not loaded]"))

        _ = await service.respond(to: ControlRequest(args: ["--tab", "2", "reload"]))
        #expect(store.tabs[1].hasContent)
        #expect(store.selectedID == store.tabs[0].id, "読み込んでも選択は動かさない")
    }

    @Test func tabCommands() async {
        var response = await run("tabs")
        #expect(response.ok)
        #expect(response.output.hasPrefix("* tab 1:"))

        response = await run("new")
        #expect(response.output.hasPrefix("* tab 2:"))
        #expect(store.tabs.count == 2)

        response = await run("select", "1")
        #expect(store.selected?.number == 1)

        response = await run("close", "2")
        #expect(response.ok)
        #expect(store.tabs.count == 1)

        response = await run("close")
        #expect(!response.ok)
        #expect(store.tabs.count == 1)
    }

    @Test func bookmarkCommands() async throws {
        #expect(await run("bookmarks").output.contains("ブックマークなし"))
        #expect(await run("ui").output.contains("bookmarks bar: (なし)"))

        try await open(html: "<title>Pinned</title>")
        var response = await run("bookmark-add", "--folder", "仕事")
        #expect(response.ok, "\(response.output)")
        #expect(response.output.contains("  1 仕事/"))
        #expect(response.output.contains("*   2 Pinned"))
        #expect(store.tabs.isEmpty, "今のタブはブックマークの側へ移る")
        #expect(await !run("bookmark-add").ok, "ブックマークのページは重ねて登録できない")

        response = await run("bookmark-add", "about:blank", "--name", "Blank")
        #expect(response.output.contains("  3 Blank — about:blank"))
        #expect(!response.output.contains("3 Blank — about:blank (open"), "URLで足しただけではページを開かない")

        response = await run("ui")
        #expect(response.output.contains("bookmarks bar: [*仕事 › Pinned ▾] [Blank]"))

        response = await run("bookmark-open", "3")
        #expect(response.ok, "\(response.output)")
        #expect(response.output.contains("[bookmark: Blank]"))
        #expect(await run("ui").output.contains("[仕事 ▾] [*Blank (open)]"))
        #expect(await !run("bookmark-open", "1").ok, "フォルダは開けない")
        #expect(await !run("bookmark-open", "9").ok)

        response = await run("bookmark-remove", "1")
        #expect(!response.output.contains("Pinned"))
        #expect(store.tabs.map(\.title) == ["Pinned"], "消したブックマークのページはタブに残る")
    }

    /// フォルダの一覧が出ているあいだ、ui に行と選択の当たりが出ること。
    @Test func folderListInUI() async {
        let folder = store.bookmarks.addFolder(named: "仕事")
        store.bookmarks.add(title: "A", url: URL(string: "about:blank")!, folder: folder.id)
        store.bookmarks.add(title: "B", url: URL(string: "about:blank")!, folder: folder.id)
        #expect(await !run("ui").output.contains("folder list"))

        store.toggleFolder(number: 1)
        store.moveFolderHighlight(by: 1)
        #expect(await run("ui").output.contains("folder list: 仕事 [1 A] [>2 B]"))

        #expect(await !run("key").ok)
        #expect(await !run("key", "f13").ok)
        #expect(await !run("key", "hyper+1").ok)
    }

    @Test func rejectsBadInput() async {
        #expect(await !run("bogus").ok)
        #expect(await !run("--tab", "99", "wait").ok)
        #expect(await !run("--tab").ok)
        #expect(await !run("click", "one").ok)
        #expect(await !run("snapshot").ok, "ページのないタブでは読めない")
        #expect(await run("help").output.contains("snapshot"))
    }

    @Test func readsAndOperatesPage() async throws {
        try await open(html: Self.form)

        var response = await run("snapshot")
        #expect(response.output.contains("Form"))
        #expect(response.output.contains("# Sign in"))
        #expect(response.output.contains(#"[1] textbox "Name""#))
        #expect(response.output.contains(#"[2] select "color" value="Red" options=[Red | Blue]"#))
        #expect(response.output.contains(#"[3] button "Go""#))
        #expect(response.output.contains(#"[4] link "Next""#))
        #expect(!response.output.contains("secret"))

        #expect(await run("fill", "1", "Mikawa", "Taro").ok)
        #expect(await run("fill", "2", "Blue").ok)
        #expect(await !run("fill", "2", "Green").ok)
        #expect(await !run("fill", "3", "x").ok)

        response = await run("click", "3")
        #expect(response.output.contains("clicked Mikawa Taro"))

        response = await run("snapshot")
        #expect(response.output.contains(#"value="Mikawa Taro""#))
        #expect(response.output.contains(#"value="Blue""#))

        #expect(await !run("click", "42").ok)
        #expect(await run("text").output.contains("Sign in"))
    }

    @Test func evaluatesExpressionsAndStatements() async throws {
        try await open(html: "<title>T</title><p>x</p>")

        #expect(await run("eval", "1 + 2").output == "3")
        #expect(await run("eval", "document.title").output == #""T""#)
        #expect(await run("eval", "const n = 2; return { n }").output == #"{"n":2}"#)
        #expect(await run("eval", "undefined").output == "null")

        let failed = await run("eval", "missingFunction()")
        #expect(!failed.ok)
        #expect(failed.output.contains("missingFunction"))
    }

    @Test func reportsWindowChrome() async throws {
        var response = await run("ui")
        #expect(response.output.contains("buttons: back=disabled forward=disabled reload=disabled"))
        #expect(response.output.contains("page: empty"))

        try await open(html: "<title>One</title>")
        response = await run("ui")
        #expect(response.output.contains("window title: One"))
        #expect(response.output.contains("reload=enabled"))
        #expect(response.output.contains("page: loaded"))
    }

    @Test func collectsConsoleOutputAndExceptions() async throws {
        try await open(html: """
        <script>
        console.log('hello', { n: 1 });
        console.warn('careful');
        Promise.reject(new Error('boom'));
        </script>
        """)
        _ = await run("wait")

        var response = await run("logs")
        #expect(response.output.contains(#"[log] hello {"n":1}"#))
        #expect(response.output.contains("[warn] careful"))
        #expect(response.output.contains("[exception]"))
        #expect(response.output.contains("boom"))

        response = await run("logs", "--limit", "1", "--clear")
        #expect(!response.output.contains("hello"))
        #expect(await run("logs").output.contains("記録なし"))
    }

    @Test func logKeepsOnlyRecentEntries() {
        let log = PageLog()
        for index in 0..<(PageLog.capacity + 10) {
            log.append(level: "log", message: "\(index)")
        }
        #expect(log.entries.count == PageLog.capacity)
        #expect(log.entries.first?.message == "10")
    }

    @Test func statsListsThisProcess() async {
        let response = await run("stats")
        #expect(response.ok)
        #expect(response.output.contains("Browser (app)"))
        #expect(response.output.contains("total"))
    }

    @Test func snapshotLimitIsReported() async throws {
        try await open(html: (1...5).map { "<a href='#\($0)'>L\($0)</a>" }.joined())

        let response = await run("snapshot", "--limit", "2")
        #expect(response.output.contains("[2] link"))
        #expect(!response.output.contains("[3]"))
        #expect(response.output.contains("3 個の要素を省略"))
    }
}
