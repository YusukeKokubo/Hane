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

    @Test func snapshotLimitIsReported() async throws {
        try await open(html: (1...5).map { "<a href='#\($0)'>L\($0)</a>" }.joined())

        let response = await run("snapshot", "--limit", "2")
        #expect(response.output.contains("[2] link"))
        #expect(!response.output.contains("[3]"))
        #expect(response.output.contains("3 個の要素を省略"))
    }
}
