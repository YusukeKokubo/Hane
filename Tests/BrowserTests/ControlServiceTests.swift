import ControlWire
import Foundation
import Testing
import WebKit
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
        #expect(listing.contains("tab 2: Waiting — \(waiting.absoluteString) [asleep]"))
        #expect(!listing.contains("Shown — \(directory.appending(path: "shown.html").absoluteString) [asleep]"))

        _ = await service.respond(to: ControlRequest(args: ["--tab", "2", "reload"]))
        #expect(store.tabs[1].hasContent)
        #expect(store.selectedID == store.tabs[0].id, "読み込んでも選択は動かさない")
    }

    /// 眠らせたタブは一覧で分かり、選べば起きる。画面に出ているタブは眠らせない。
    @Test func sleepCommand() async throws {
        try await open(html: "<title>First</title>")
        _ = await run("new")
        try await open(html: "<title>Second</title>")

        #expect(await !run("sleep", "2").ok, "選択中のタブは眠らせない")
        let slept = await run("sleep", "1")
        #expect(slept.ok, "\(slept.output)")
        #expect(slept.output.contains("tab 1: First"), "\(slept.output)")
        #expect(slept.output.contains("[asleep]"))
        #expect(await !run("sleep", "1").ok, "もう眠っている")

        let selected = await run("select", "1")
        #expect(!selected.output.contains("[asleep]"), "\(selected.output)")
        #expect(store.tabs[0].hasContent)
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

    @Test func windowScreenshotNeedsAWindow() async {
        // テストには窓がないので、撮れないことを分かる言葉で返すことだけを見る。
        let response = await run("window-screenshot")
        #expect(!response.ok)
        #expect(response.output.contains("窓が出ていない"))
    }

    @Test func windowElementCommandsExplainWhatIsMissing() async {
        // テストには窓がないので、番号のない操作と、窓が要る操作が分かる言葉で断ることを見る。
        var response = await run("ui-click", "1")
        #expect(!response.ok)
        #expect(response.output.contains("ui-snapshot"))
        #expect(await !run("ui-click").ok)
        #expect(await !run("ui-hover", "x").ok)
        #expect(await run("ui-hover", "tab:Second").output.contains("窓が出ていない"), "名前で指すときは窓から拾い直す")
        #expect(await !run("ui-menu", "1").ok)

        response = await run("window-size", "800", "600")
        #expect(response.output.contains("窓が出ていない"))
        #expect(await run("appearance", "sepia").output.contains("dark、light、system"))
    }

    @Test func uiReportsWindowFrame() async {
        // テストには窓がないので、行があって「なし」と出ることだけを見る。
        let ui = await run("ui").output
        #expect(ui.contains("window frame: (なし)"))
        #expect(ui.contains("app: pid \(getpid()), started "), "古い版が動いていないか確かめられるよう、起動と作った時刻を出す")
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

        store.toggleFolder(folder.id)
        store.moveFolderHighlight(by: 1)
        #expect(await run("ui").output.contains("folder list: 仕事 [1 A] [>2 B]"))

        #expect(await !run("key").ok)
        #expect(await !run("key", "f13").ok)
        #expect(await !run("key", "hyper+1").ok)
    }

    @Test func listsHistory() async throws {
        #expect(await run("history").output == "（履歴なし）")
        try await open(html: "<title>Visited</title>")
        for _ in 0..<50 where store.history.entries.values.first?.title.isEmpty != false {
            try await Task.sleep(for: .milliseconds(20))
        }
        let listing = await run("history").output
        #expect(listing.contains("typed 0 visits 1  Visited — file://"))
    }

    @Test func rejectsBadInput() async {
        #expect(await !run("bogus").ok)
        #expect(await !run("type").ok)
        #expect(await !run("type", "abc").ok, "入力欄にフォーカスがない（テストではウインドウがない）")
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
        // 題名は読み込みの完了より遅れて届くことがあり、待たないとたまに落ちた。
        for _ in 0..<50 where store.selected?.title != "One" {
            try await Task.sleep(for: .milliseconds(20))
        }
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
        #expect(response.output.contains("wakeups/s"))
    }

    @Test func statsCanBeReadByMachines() async throws {
        let response = await run("stats", "--seconds", "0.2", "--json")
        #expect(response.ok)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(response.output.utf8)) as? [String: Any])
        let report = try #require(object["report"] as? [String: Any])
        #expect((report["seconds"] as? Double ?? 0) >= 0.2)
        #expect(report["total"] is [String: Any])
        #expect(object["tabs"] is [String: Any])
    }

    /// ページのプロセスは WebKit の中身から引いているので、WebKit が変わると引けなくなる。それを知らせる。
    @Test func pageProcessIsFound() async throws {
        try await open(html: "<title>Process</title>")
        let tab = try #require(store.selected)
        let pid = try #require(tab.page.flatMap(PageProcess.identifier(of:)))
        #expect(pid != getpid())

        let response = await run("stats", "--seconds", "0.1", "--json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(response.output.utf8)) as? [String: Any])
        let report = try #require(object["report"] as? [String: Any])
        // 補助プロセスを特定できない環境では、アプリ本体しか並ばない。
        guard report["appOnly"] as? Bool == false else { return }
        let processes = try #require(report["processes"] as? [[String: Any]])
        let row = try #require(processes.first { $0["pid"] as? Int == Int(pid) }, "\(processes)")
        #expect(row["tabs"] as? [Int] == [tab.number])
    }

    /// 設定を別々に作るとプロセスプールも分かれ、「戻る」用のページと予備のプロセスがタブの数だけ溜まる。
    /// 設定を一つ写して使っているので、プールと環境設定は全ページで同じものになる。
    @Test func pagesShareOneProcessPool() async throws {
        try await open(html: "<title>One</title>")
        _ = await run("new")
        try await open(html: "<title>Two</title>")
        let views = store.allTabs.compactMap { $0.page?.webView }
        try #require(views.count == 2)
        let pools = views.map { $0.configuration.value(forKey: "processPool") as AnyObject }
        #expect(pools[0] === pools[1])
        // 設定画面で変えた値を開いているタブにもその場で効かせるため、環境設定も共有している。
        #expect(views.allSatisfy { $0.configuration.preferences === SharedConfiguration.preferences })
        // 別のプロファイルのページとも共有する。
        let other = PageFactory(dataStore: .nonPersistent()).makePage(opener: nil, log: PageLog()) { _ in }
        #expect(other.webView.configuration.value(forKey: "processPool") as AnyObject === pools[0])
    }

    /// `window.open` は、止めているときは操作の中から呼んだものだけ、許しているときはいつでも新しいタブで開く。
    @Test func popupsFollowTheSetting() async throws {
        let second = FileManager.default.temporaryDirectory.appending(path: "control-popup-\(UUID().uuidString).html")
        try "<title>Popped</title>".write(to: second, atomically: true, encoding: .utf8)
        let target = second.absoluteString
        // 環境設定はほかのテストのページとも共有なので、許したままにしない。
        defer { SharedConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false }
        let popup = "<title>Opener</title><script>setTimeout(() => window.open('\(target)#auto'), 50)</script>"

        #expect(await run("settings").output == "popups: block")
        try await open(html: popup)
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.tabs.count == 1)

        // eval はクリックと同じく利用者の操作の中として扱われる。
        _ = await run("eval", "window.open('\(target)#click'); 1")
        try await waitForTabs(2)
        #expect(store.selected?.url?.fragment == "click")

        #expect(await run("settings", "popups", "allow").output == "popups: allow")
        _ = await run("select", "1")
        _ = await run("reload")
        try await waitForTabs(3)
        #expect(store.selected?.url?.fragment == "auto")

        #expect(await !run("settings", "popups", "maybe").ok)
        #expect(await !run("settings", "cookies", "block").ok)
    }

    /// 大きさを指定した window.open（ログインの小窓など）は別の窓で開いてページへ返し、opener でつながる。
    /// 小窓が window.close() を呼ぶと窓も閉じる。
    @Test func sizedPopupsOpenInTheirOwnWindow() async throws {
        let login = FileManager.default.temporaryDirectory.appending(path: "control-login-\(UUID().uuidString).html")
        try "<title>Login</title>".write(to: login, atomically: true, encoding: .utf8)
        try await open(html: "<title>Opener</title>")
        // 小窓の一覧はアプリ全体で一つで、並んで走るほかのテストの小窓も入るので、開いた側で見分ける。
        var popups: Int { PopupWindows.windows.count { $0.opener === store } }

        let opened = await run("eval", "window.login = window.open('\(login.absoluteString)', 'login', 'width=400,height=300'); return String(window.login !== null)")
        #expect(opened.output == "\"true\"")
        #expect(popups == 1)
        #expect(store.tabs.count == 1)
        #expect(await run("eval", "String(window.login.opener === window)").output == "\"true\"")

        _ = await run("eval", "window.login.close(); 1")
        for _ in 0..<50 where popups > 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(popups == 0)
    }

    private func waitForTabs(_ count: Int) async throws {
        for _ in 0..<50 where store.tabs.count < count {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(store.tabs.count == count)
    }

    /// 読み込む前のタブのために Web ビューを作らせない。
    @Test func pageProcessIsNotCreatedForEmptyTabs() {
        let tab = store.newTab()
        #expect(tab.page == nil)
    }

    @Test func statsRejectsTooLongMeasurements() async {
        let response = await run("stats", "--seconds", "600")
        #expect(!response.ok)
    }

    @Test func snapshotLimitIsReported() async throws {
        try await open(html: (1...5).map { "<a href='#\($0)'>L\($0)</a>" }.joined())

        let response = await run("snapshot", "--limit", "2")
        #expect(response.output.contains("[2] link"))
        #expect(!response.output.contains("[3]"))
        #expect(response.output.contains("3 個の要素を省略"))
    }
}
