import AppKit
import ControlWire
import Foundation
import Testing
import WebKit
@testable import Hane

/// プロファイルの一覧と名前の決まり、一つの実体の中での切り替え。
@MainActor
@Suite struct ProfileTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString)")
    private var file: URL { ProfileRegistry.fileURL(in: directory) }

    /// 保存する置き場を試すモデル。WebKit のサイトデータの置き場は作らない。
    private func persistentModel() -> BrowserModel {
        BrowserModel(directory: directory, contentBlocker: nil, keepsSiteData: false)
    }

    private func temporaryModel() -> BrowserModel {
        BrowserModel(directory: nil, contentBlocker: nil)
    }

    /// HTMLを一時ファイルに書く。ネットワークには出ない。
    private func writePage(_ html: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "profile-test-\(UUID().uuidString).html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func namesThatBecomePathsAreChecked() {
        #expect(BrowserProfile.problem(withName: "仕事") == nil)
        #expect(BrowserProfile.problem(withName: "プライベート") == nil)
        #expect(BrowserProfile.problem(withName: "work-2") == nil)
        for bad in ["", "default", " 仕事", ".hidden", "a/b", "a:b", "a\nb", String(repeating: "長", count: 30)] {
            #expect(BrowserProfile.problem(withName: bad) != nil, "\(bad)")
        }
        #expect(BrowserInstance.problem(withName: "dev") == nil)
        for bad in ["", "a/b", ".x", String(repeating: "長", count: 40)] {
            #expect(BrowserInstance.problem(withName: bad) != nil, "\(bad)")
        }
    }

    @Test func registryKeepsDataStoreForEachName() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var registry = try ProfileRegistry.load(from: file)
        #expect(registry.profiles.isEmpty, "ファイルがなければ空")
        let work = try registry.add("仕事")
        try registry.save(to: file)

        let loaded = try ProfileRegistry.load(from: file)
        #expect(loaded.entry(named: "仕事") == work, "識別子ごと残る")
        var again = loaded
        #expect(throws: ProfileError.self) { try again.add("仕事") }
        #expect(throws: ProfileError.self) { try again.add("a/b") }
    }

    /// 最後に開いたプロファイルは後から足した項目なので、前の版の一覧もそのまま読める。
    @Test func registryWithoutLastOpenedLoads() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"profiles":[{"name":"仕事","dataStore":"A44A9518-C9B7-474F-87F3-5A167B3C157D"}]}"#.utf8).write(to: file)
        let registry = try ProfileRegistry.load(from: file)
        #expect(registry.profiles.map(\.name) == ["仕事"])
        #expect(registry.lastOpened == nil)
    }

    /// 読めない一覧を空として上書きすると、名前とサイトデータの対応が失われる。
    @Test func brokenRegistryIsNotOverwritten() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: file)
        #expect(throws: ProfileError.self) { try ProfileRegistry.load(from: file) }

        let model = persistentModel()
        #expect(model.names == [BrowserProfile.defaultName])
        #expect(throws: (any Error).self) { try model.create("仕事") }
        #expect(try Data(contentsOf: file) == Data("{".utf8))
    }

    @Test func modelListsDefaultThenRegistered() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = persistentModel()
        #expect(model.names == [BrowserProfile.defaultName])
        #expect(try model.create(" 仕事 ") == "仕事", "前後の空白は落とす")
        _ = try model.create("趣味")
        #expect(model.names == [BrowserProfile.defaultName, "仕事", "趣味"])
        #expect(try ProfileRegistry.load(from: file).profiles.map(\.name) == ["仕事", "趣味"])
        #expect(throws: ProfileError.self) { try model.create("仕事") }
    }

    /// 使い捨ての実体は、登録した一覧を見せず、書き換えもしない。
    @Test func temporaryModelDoesNotTouchRegistry() throws {
        let model = temporaryModel()
        #expect(model.names == [BrowserProfile.defaultName])
        _ = try model.create("仕事")
        #expect(model.names == [BrowserProfile.defaultName, "仕事"])
        #expect(throws: ProfileError.self) { try model.create("仕事") }
        #expect(throws: ProfileError.self) { try model.create("a/b") }
    }

    @Test func switchingToItselfStays() throws {
        let model = temporaryModel()
        let store = model.store
        #expect(try model.switchTo(BrowserProfile.defaultName) == false)
        #expect(model.store === store)
        #expect(throws: ProfileError.self) { try model.switchTo("ない") }
    }

    /// 離れたプロファイルのページは残さない。掴み残しがあると、プロファイルを行き来するたびにページが溜まる。
    @Test func switchingReleasesThePagesOfTheProfileLeft() async throws {
        let model = temporaryModel()
        _ = try model.create("仕事")
        weak var page: Page?
        weak var tab: Tab?
        weak var store: TabStore?
        do {
            let opened = model.store.open(URLRequest(url: try writePage("<title>Left</title>")))
            page = opened.page
            tab = opened
            store = model.store
            try model.switchTo("仕事")
        }
        // 監視タスクの後始末が走るのを待つ。
        for _ in 0..<50 where page != nil || tab != nil || store != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store == nil)
        #expect(tab == nil)
        #expect(page == nil)
        #expect(model.current == "仕事")
    }

    /// ページの判断は非同期なので、離れたあとに古いタブ管理へ新しいタブの頼みが届くことがある。
    @Test func profileLeftOpensNothingAndWritesNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = persistentModel()
        _ = try model.create("仕事")
        let old = model.store
        old.open(URLRequest(url: try writePage("<title>Kept</title>")))
        try model.switchTo("仕事")
        #expect(old.isShutDown)
        #expect(old.allTabs.isEmpty)

        let sessionFile = directory.appending(path: "session.json")
        let saved = try Data(contentsOf: sessionFile)
        old.openTab(with: URLRequest(url: URL(string: "about:blank")!), inBackground: false)
        old.saveSession()
        #expect(old.allTabs.isEmpty, "閉じたあとは開かない")
        #expect(try Data(contentsOf: sessionFile) == saved, "閉じたあとは書かない")
    }

    /// 戻ると、離れたときに開いていたページが戻る。次の起動では最後に開いていたプロファイルで始まる。
    @Test func switchingBackRestoresTabsAndIsRemembered() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try writePage("<title>Kept</title>")
        let model = persistentModel()
        _ = try model.create("仕事")
        model.store.open(URLRequest(url: kept))

        try model.switchTo("仕事")
        #expect(model.store.allTabs.allSatisfy { $0.url == nil }, "移った先は空のタブ")
        #expect(try ProfileRegistry.load(from: file).lastOpened == "仕事")

        try model.switchTo(BrowserProfile.defaultName)
        #expect(model.store.allTabs.contains { $0.url == kept })
        #expect(try ProfileRegistry.load(from: file).lastOpened == nil, "標準に戻ったら覚えない")

        try model.switchTo("仕事")
        let next = persistentModel()
        #expect(next.current == "仕事")
    }

    /// 使い捨ての実体でも、プロファイルを行き来すると閲覧状態が戻る（ファイルには書かない）。
    @Test func temporaryProfilesKeepTheirTabsInMemory() throws {
        let kept = try writePage("<title>Kept</title>")
        let model = temporaryModel()
        _ = try model.create("仕事")
        model.store.open(URLRequest(url: kept))
        try model.switchTo("仕事")
        try model.switchTo(BrowserProfile.defaultName)
        #expect(model.store.allTabs.contains { $0.url == kept })
    }

    /// サイトデータはプロファイルごとに分かれ、全タブで一つのプロセスプールを共有していても混ざらない。
    /// 戻れば同じサイトデータを使う。
    @Test func siteDataIsSeparatedPerProfile() async throws {
        let model = temporaryModel()
        _ = try model.create("仕事")
        let service = ControlService(model: model)
        let url = try writePage("<title>Storage</title>").absoluteString
        func run(_ args: String...) async throws -> String {
            let response = await service.respond(to: ControlRequest(args: args))
            try #require(response.ok, "\(response.output)")
            return response.output
        }

        _ = try await run("open", url)
        _ = try await run("eval", "localStorage.setItem('mark', 'default'); 1")
        #expect(try await run("eval", "localStorage.getItem('mark')") == "\"default\"")

        _ = try await run("profile-open", "仕事")
        _ = try await run("open", url)
        #expect(try await run("eval", "String(localStorage.getItem('mark'))") == "\"null\"")

        _ = try await run("profile-open", BrowserProfile.defaultName)
        _ = try await run("open", url)
        #expect(try await run("eval", "localStorage.getItem('mark')") == "\"default\"")
    }

    /// 離れるプロファイルが開いた小窓（ログインの小窓など）は閉じる。前のプロファイルのサイトデータを使っているため。
    @Test func switchingClosesPopupsOfTheProfileLeft() async throws {
        let model = temporaryModel()
        _ = try model.create("仕事")
        let service = ControlService(model: model)
        let login = try writePage("<title>Login</title>").absoluteString
        _ = await service.respond(to: ControlRequest(args: ["open", try writePage("<title>Opener</title>").absoluteString]))
        let opened = await service.respond(to: ControlRequest(
            args: ["eval", "String(window.open('\(login)', 'login', 'width=400,height=300') !== null)"]))
        #expect(opened.output == "\"true\"")
        // 小窓の一覧はアプリ全体で一つで、並んで走るほかのテストの小窓も入るので、開いた側で見分ける。
        let popup = try #require(PopupWindows.windows.first { $0.opener === model.store })

        try model.switchTo("仕事")
        #expect(!PopupWindows.windows.contains { $0 === popup })
    }

    /// ⌃N と ⌃Tab だけを拾い、並んでいない番号やほかの修飾キーはページなど本来の受け手へ流す。
    @Test func localShortcuts() throws {
        let model = temporaryModel()
        _ = try model.create("仕事")
        let first = model.store.tabs[0]
        let second = model.store.newTab()
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: keyCode)!
        }
        func handle(_ event: NSEvent) -> Bool { LocalShortcuts.handle(event, model: model) }

        #expect(!handle(key("3", .control)))
        #expect(!handle(key("2", .command)), "⌘2 はメニューのバーの項目")
        #expect(!handle(key("2", [.command, .option])), "⌥⌘数字はページの見出しなどに残す")

        #expect(handle(key("\t", .control, keyCode: 48)))
        #expect(model.store.selectedID == first.id, "最後のタブの次は最初へ巡る")
        #expect(handle(key("\t", [.control, .shift], keyCode: 48)))
        #expect(model.store.selectedID == second.id)
        #expect(!handle(key("\t", [], keyCode: 48)), "Tab だけはページの入力欄へ")

        #expect(handle(key("1", .control)), "1 番目は今のプロファイル（移らない）")
        #expect(model.current == BrowserProfile.defaultName)
        #expect(handle(key("2", .control)))
        #expect(model.current == "仕事")
    }

    @Test func profileCommands() async {
        let service = ControlService(model: temporaryModel())
        func run(_ args: String...) async -> ControlResponse {
            await service.respond(to: ControlRequest(args: args))
        }

        var response = await run("profiles")
        #expect(response.ok)
        #expect(response.output.contains("* 標準 (default)"))
        #expect(response.output.contains("使い捨て"))

        response = await run("profile-new", "仕事")
        #expect(response.ok, "\(response.output)")
        #expect(response.output.contains("  仕事"))

        response = await run("profile-new", "a/b")
        #expect(!response.ok)
        #expect(response.output.contains("使えない名前"))

        response = await run("profile-open", BrowserProfile.defaultName)
        #expect(response.output == "already here: default")

        response = await run("profile-open", "仕事")
        #expect(response.output.hasPrefix("switched: 仕事"))
        #expect(await run("profiles").output.contains("* 仕事"))
        #expect(await run("ui").output.contains("profile: 仕事"))

        response = await run("pid")
        #expect(response.output == "pid \(getpid())")
    }
}
