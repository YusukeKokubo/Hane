import AppKit
import ControlWire
import Foundation
import Testing
import WebKit
@testable import Hane

/// プロファイルの一覧と名前の決まり、窓一枚に一つずつ出すプロファイルの開き方と閉じ方。
@MainActor
@Suite struct ProfileTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString)")
    private var file: URL { ProfileRegistry.fileURL(in: directory) }

    init() {
        // テストの実行環境ではアプリの本体（`NSApp`）が誰かが窓を作るまでできず、`ui` のような窓まわりの命令が先に走ると落ちる。
        _ = NSApplication.shared
        MainRunLoop.keepRunning()
    }

    /// 保存する置き場を試すモデル。WebKit のサイトデータの置き場は作らない。
    private func persistentModel() -> BrowserModel {
        BrowserModel(directory: directory, contentBlocker: nil, keepsSiteData: false)
    }

    private func temporaryModel() -> BrowserModel {
        BrowserModel(directory: nil, contentBlocker: nil)
    }

    /// 起動したときの窓を開く。AppKit の窓は作らない。最初に開いた窓を返す。
    @discardableResult
    private func launch(_ model: BrowserModel) -> BrowserWindowSlot {
        model.restoreWindows()
        return model.windows[0]
    }

    /// 窓をすべて閉じたあとに、Dock などで開き直す。
    private func reopen(_ model: BrowserModel) -> BrowserWindowSlot {
        model.reopen()
        return model.windows[model.windows.count - 1]
    }

    /// 新しい窓で開く。
    private func openInNewWindow(_ name: String, in model: BrowserModel) throws -> BrowserWindowSlot {
        #expect(try model.openProfile(name) == .openedInNewWindow)
        let window = try #require(model.window(showing: name))
        #expect(model.activeWindow === window)
        return window
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

    @Test func openingTheShownProfileStays() throws {
        let model = temporaryModel()
        let window = launch(model)
        let store = try #require(model.store)
        #expect(try model.openProfile(BrowserProfile.defaultName) == .alreadyHere)
        #expect(model.store === store)
        #expect(model.activeWindow === window)
        #expect(throws: ProfileError.self) { try model.openProfile("ない") }
    }

    /// 窓を閉じると、そのプロファイルのページを残さない。掴み残しがあると、窓を開け閉めするたびにページが溜まる。
    /// 最後の一枚でも閉じ、窓がない間は今のタブ管理もない。
    @Test func closingAWindowReleasesItsPages() async throws {
        let model = temporaryModel()
        _ = try model.create("仕事")
        let first = launch(model)
        let standard = try #require(first.store)
        weak var page: Page?
        weak var tab: Tab?
        weak var store: TabStore?
        do {
            let second = try openInNewWindow("仕事", in: model)
            let work = try #require(second.store)
            #expect(model.store === work, "新しい窓が今のものになる")
            let opened = work.open(URLRequest(url: try writePage("<title>Left</title>")))
            page = opened.page
            tab = opened
            store = work
            model.detach(second)
        }
        // 監視タスクの後始末が走るのを待つ。
        for _ in 0..<50 where page != nil || tab != nil || store != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store == nil)
        #expect(tab == nil)
        #expect(page == nil)
        #expect(model.current == BrowserProfile.defaultName)
        #expect(!standard.isShutDown, "ほかの窓のページは閉じない")

        model.detach(first)
        #expect(standard.isShutDown, "最後の窓でも閉じる")
        #expect(model.store == nil)
        #expect(model.current == nil)
    }

    /// ページの判断は非同期なので、窓を閉じたあとに古いタブ管理へ新しいタブの頼みが届くことがある。
    @Test func closedProfileOpensNothingAndWritesNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = persistentModel()
        let window = launch(model)
        let old = try #require(model.store)
        old.open(URLRequest(url: try writePage("<title>Kept</title>")))
        model.detach(window)
        #expect(old.isShutDown)
        #expect(old.allTabs.isEmpty)

        let sessionFile = directory.appending(path: "session.json")
        let saved = try Data(contentsOf: sessionFile)
        old.openTab(with: URLRequest(url: URL(string: "about:blank")!), inBackground: false)
        old.saveSession()
        #expect(old.allTabs.isEmpty, "閉じたあとは開かない")
        #expect(try Data(contentsOf: sessionFile) == saved, "閉じたあとは書かない")
    }

    /// ほかのプロファイルは新しい窓で開き、今の窓のタブは閉じない。窓を閉じてから開き直すと、閉じたときのタブが戻る。
    /// 次の起動では、最後に前にあったプロファイルで始まる。
    @Test func reopeningRestoresTabsAndIsRemembered() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try writePage("<title>Kept</title>")
        let model = persistentModel()
        _ = try model.create("仕事")
        let first = launch(model)
        let standard = try #require(first.store)
        standard.open(URLRequest(url: kept))

        let second = try openInNewWindow("仕事", in: model)
        #expect(try #require(second.store).allTabs.allSatisfy { $0.url == nil }, "開いた先は空のタブ")
        #expect(standard.allTabs.contains { $0.url == kept }, "前の窓のタブは残る")
        #expect(!standard.isShutDown)
        #expect(try ProfileRegistry.load(from: file).lastOpened == "仕事")

        model.detach(second)
        #expect(model.current == BrowserProfile.defaultName)
        #expect(try ProfileRegistry.load(from: file).lastOpened == nil, "標準に戻ったら覚えない")

        // 最後の窓を閉じてから、Dock などで開き直す。
        model.detach(first)
        let reopened = reopen(model)
        #expect(reopened.profile == BrowserProfile.defaultName)
        #expect(reopened.store !== standard)
        #expect(try #require(reopened.store).allTabs.contains { $0.url == kept })

        _ = try openInNewWindow("仕事", in: model)
        model.saveBeforeQuit()
        let next = persistentModel()
        let restored = launch(next)
        #expect(restored.profile == "仕事")
        #expect(next.windows.count == 2)
    }

    /// 使い捨ての実体でも、窓を閉じてから開き直すと閲覧状態が戻る（ファイルには書かない）。
    @Test func temporaryProfilesKeepTheirTabsInMemory() throws {
        let kept = try writePage("<title>Kept</title>")
        let model = temporaryModel()
        let window = launch(model)
        try #require(model.store).open(URLRequest(url: kept))
        model.detach(window)
        _ = reopen(model)
        #expect(try #require(model.store).allTabs.contains { $0.url == kept })
    }

    /// サイトデータはプロファイルごとに分かれ、全タブで一つのプロセスプールを共有していても混ざらない。
    /// 窓を閉じて開き直しても、同じサイトデータを使う。
    @Test func siteDataIsSeparatedPerProfile() async throws {
        let model = temporaryModel()
        _ = try model.create("仕事")
        let standard = launch(model)
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

        #expect(try await run("profile-open", "仕事").hasPrefix("opened in new window: 仕事"))
        _ = try await run("open", url)
        #expect(try await run("eval", "String(localStorage.getItem('mark'))") == "\"null\"")

        #expect(try await run("profile-open", BrowserProfile.defaultName).hasPrefix("brought to front: default"))
        #expect(try await run("eval", "localStorage.getItem('mark')") == "\"default\"", "前の窓のページは生きている")

        model.detach(standard)
        #expect(try await run("profile-open", BrowserProfile.defaultName).hasPrefix("opened in new window: default"))
        _ = try await run("open", url)
        #expect(try await run("eval", "localStorage.getItem('mark')") == "\"default\"")
    }

    /// 窓を閉じたプロファイルが開いた小窓（ログインの小窓など）は閉じる。そのプロファイルのサイトデータを使っているため。
    @Test func closingAWindowClosesPopupsOfItsProfile() async throws {
        let model = temporaryModel()
        let window = launch(model)
        let service = ControlService(model: model)
        let login = try writePage("<title>Login</title>").absoluteString
        _ = await service.respond(to: ControlRequest(args: ["open", try writePage("<title>Opener</title>").absoluteString]))
        let opened = await service.respond(to: ControlRequest(
            args: ["eval", "String(window.open('\(login)', 'login', 'width=400,height=300') !== null)"]))
        #expect(opened.output == "\"true\"")
        // 小窓の一覧はアプリ全体で一つで、並んで走るほかのテストの小窓も入るので、開いた側で見分ける。
        let store = try #require(model.store)
        let popup = try #require(PopupWindows.windows.first { $0.opener === store })

        model.detach(window)
        #expect(!PopupWindows.windows.contains { $0 === popup })
    }

    /// メニューのキーで、⌃N は N 番目のプロファイル、⌃Tab / ⌃⇧Tab は前後のタブ。並んでいない番号やほかの修飾キーは
    /// ページなど本来の受け手へ流す。メニューを組んだあとに足したプロファイルにも、メニューを開かずに効く。
    @Test func menuKeys() async throws {
        let model = temporaryModel()
        launch(model)
        let menu = MainMenu(model: model, settings: SettingsStore())
        _ = try model.create("仕事")
        // 一覧の変化を受けて作り直すのは、次の一巡り。
        await Task.yield()
        let store = try #require(model.store)
        let first = store.tabs[0]
        let second = store.newTab()
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: keyCode)!
        }
        func handle(_ event: NSEvent) -> Bool { menu.menu.performKeyEquivalent(with: event) }

        #expect(!handle(key("3", .control)))
        #expect(!handle(key("2", [.command, .option])), "⌥⌘数字はページの見出しなどに残す")

        #expect(handle(key("\t", .control, keyCode: 48)))
        #expect(store.selectedID == first.id, "最後のタブの次は最初へ巡る")
        #expect(handle(key("\t", [.control, .shift], keyCode: 48)))
        #expect(store.selectedID == second.id)
        // 本物の ⌃⇧Tab は文字が backtab で届く。
        #expect(handle(key("\u{19}", [.control, .shift], keyCode: 48)))
        #expect(store.selectedID == first.id)
        #expect(!handle(key("\t", [], keyCode: 48)), "Tab だけはページの入力欄へ")

        #expect(handle(key("1", .control)), "1 番目は今のプロファイル（何も開かない）")
        #expect(model.windows.count == 1)
        #expect(handle(key("2", .control)), "メニューを組んだあとに足したプロファイル")
        #expect(model.windows.count == 2, "2 番目は新しい窓で開く")
        #expect(model.current == "仕事")
        #expect(!store.isShutDown)
    }

    @Test func profileCommands() async {
        let model = temporaryModel()
        // 起動したときの窓を閉じて、窓がひとつもない所から始める。
        model.detach(launch(model))
        let service = ControlService(model: model)
        func run(_ args: String...) async -> ControlResponse {
            await service.respond(to: ControlRequest(args: args))
        }

        var response = await run("profiles")
        #expect(response.ok)
        #expect(response.output.contains("  標準 (default)"), "窓がなければ今のものはない")
        #expect(response.output.contains("使い捨て"))

        response = await run("tabs")
        #expect(!response.ok, "窓がなければタブへの命令は断る")
        #expect(response.output.contains("窓がない"))
        #expect(await run("ui").output.contains("プロファイルを出している窓がない"))

        response = await run("profile-new", "仕事")
        #expect(response.ok, "\(response.output)")
        #expect(response.output.contains("  仕事"))

        response = await run("profile-new", "a/b")
        #expect(!response.ok)
        #expect(response.output.contains("使えない名前"))

        response = await run("profile-open", BrowserProfile.defaultName)
        #expect(response.output.hasPrefix("opened in new window: default"), "\(response.output)")

        response = await run("profile-open", BrowserProfile.defaultName)
        #expect(response.output == "already here: default")

        response = await run("profile-open", "仕事")
        #expect(response.output.hasPrefix("opened in new window: 仕事"), "\(response.output)")
        let profiles = await run("profiles").output
        #expect(profiles.contains("* 仕事"))
        #expect(profiles.contains("+ 標準 (default)"))
        #expect(await run("ui").output.contains("profile: 仕事"))

        response = await run("pid")
        #expect(response.output == "pid \(getpid())")
    }

    // MARK: 窓

    /// 窓一枚にプロファイルを一つずつ出す。⌘N の窓はプロファイルを選ぶまで空で、選んでもほかの窓のページは閉じない。
    /// 一度出した窓のプロファイルは入れ替えない。
    @Test func eachWindowShowsItsOwnProfile() throws {
        let model = temporaryModel()
        _ = try model.create("仕事")
        _ = try model.create("趣味")
        let first = launch(model)
        #expect(first.profile == BrowserProfile.defaultName)
        let standard = try #require(first.store)

        let second = model.openEmptyWindow()
        #expect(second.profile == nil, "⌘N の窓はプロファイルを選ぶ前")
        #expect(second.store == nil)
        #expect(model.store === standard, "選ぶ前の窓は今のものにならない")

        #expect(try model.openProfile("仕事", in: second) == .shownInEmptyWindow)
        #expect(second.profile == "仕事")
        #expect(model.current == "仕事")
        #expect(model.store === second.store)
        #expect(first.store === standard)
        #expect(!standard.isShutDown, "ほかの窓のページは閉じない")

        model.activate(first)
        #expect(model.current == BrowserProfile.defaultName)
        #expect(model.store === standard)

        // ほかの窓に出ているプロファイルを選ぶと、その窓が前に出るだけ。
        #expect(try model.openProfile("仕事", in: first) == .broughtToFront)
        #expect(first.profile == BrowserProfile.defaultName)
        #expect(model.activeWindow === second)
        #expect(try model.openProfile("仕事") == .alreadyHere)

        // 手前がプロファイルを選ぶ前の窓なら、メニューやキーで選んでもその窓に出す。
        let third = model.openEmptyWindow()
        model.activate(third)
        #expect(model.current == "仕事", "選ぶ前の窓が前に出ても、今のものは変えない")
        #expect(try model.openProfile("趣味") == .shownInEmptyWindow)
        #expect(third.profile == "趣味")

        // 出ていないプロファイルは新しい窓で開く。重ねて開いても、窓は一枚。
        model.detach(first)
        #expect(try model.openProfile(BrowserProfile.defaultName) == .openedInNewWindow)
        #expect(try model.openProfile(BrowserProfile.defaultName) == .alreadyHere)
        #expect(second.profile == "仕事" && third.profile == "趣味", "今の窓は入れ替えない")
        let fourth = try #require(model.window(showing: BrowserProfile.defaultName))
        #expect(model.activeWindow === fourth)
        #expect(model.windows.count == 3)
        #expect(model.openEmptyWindow().profile == nil)
    }

    /// 次の起動では、終えたときに窓を開いていたプロファイルをそれぞれの窓に戻す。最後に前にあったものを最初に開く。
    @Test func windowsAreRestoredOnNextLaunch() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = persistentModel()
        _ = try model.create("仕事")
        let first = launch(model)
        let second = try openInNewWindow("仕事", in: model)
        model.activate(first)
        model.saveBeforeQuit()
        // 終えるときに窓が閉じても、戻す一覧は変えず、タブも閉じない（書き出しは済んでいる）。
        model.detach(second)
        #expect(second.store?.isShutDown == false)
        var registry = try ProfileRegistry.load(from: file)
        #expect(registry.lastOpened == nil)
        #expect(registry.lastWindows == [BrowserProfile.defaultName, "仕事"])

        let next = persistentModel()
        var opened: [BrowserWindowSlot] = []
        next.makeWindow = { opened.append($0) }
        next.restoreWindows()
        #expect(opened.count == 2, "戻す窓をその場で順に開く")
        let restored = (next.windows[0], next.windows[1])
        #expect(restored.0.profile == BrowserProfile.defaultName)
        #expect(restored.1.profile == "仕事")
        #expect(next.activeWindow === restored.0)

        // 窓が一枚に戻れば、窓の一覧は書かない。
        next.detach(restored.0)
        registry = try ProfileRegistry.load(from: file)
        #expect(registry.lastOpened == "仕事")
        #expect(registry.lastWindows == nil)
    }

    @Test func externalLinksOpenInTheLastProfileWindow() throws {
        #expect(ExternalLinks.url(from: "https://example.com/a") != nil)
        #expect(ExternalLinks.url(from: "mailto:someone@example.com") == nil)
        #expect(ExternalLinks.url(from: "file:///etc/hosts") == nil)

        let model = temporaryModel()
        _ = try model.create("仕事")
        let first = launch(model)
        let second = try openInNewWindow("仕事", in: model)
        let work = try #require(second.store)
        let standard = try #require(first.store)
        let page = try writePage("<p>外から</p>")

        // 開いたばかりの空のタブは使い回す。
        let blank = try #require(work.selected)
        #expect(ExternalLinks.place(page, in: model))
        #expect(work.selected === blank)
        #expect(blank.hasContent)

        // 中身のあるタブが選ばれていれば、新しいタブで開く。
        let before = work.tabs.count
        ExternalLinks.place(page, in: model)
        #expect(work.tabs.count == before + 1)
        #expect(standard.tabs.allSatisfy { !$0.hasContent }, "前に出ていない窓のプロファイルには開かない")

        // プロファイルの窓をすべて閉じ、プロファイルを選ぶ前の窓だけが残ったときは、最後に前にあったプロファイルを出して開く。
        model.activate(first)
        let picker = model.openEmptyWindow()
        model.detach(second)
        model.detach(first)
        #expect(picker.profile == nil)
        #expect(model.store == nil)
        #expect(ExternalLinks.place(page, in: model))
        #expect(picker.profile == BrowserProfile.defaultName)
        #expect(picker.store?.selected?.hasContent == true)

        // 窓がひとつもなければ置かない（窓を開いてもらってから置く）。
        model.detach(picker)
        #expect(!ExternalLinks.place(page, in: model))
        #expect(model.windows.isEmpty, "置くだけでは窓を開かない")
    }
}
