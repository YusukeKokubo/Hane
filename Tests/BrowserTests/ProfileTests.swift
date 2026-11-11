import ControlWire
import Foundation
import Testing
@testable import Browser

/// プロファイルの一覧と名前の決まり。実体を起こすところはここでは試さない（verify.sh で見る）。
@MainActor
@Suite struct ProfileTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString)")
    private var file: URL { directory.appending(path: "profiles.json") }

    @Test func namesThatBecomePathsAreChecked() {
        #expect(BrowserProfile.problem(withName: "仕事") == nil)
        #expect(BrowserProfile.problem(withName: "プライベート") == nil)
        #expect(BrowserProfile.problem(withName: "work-2") == nil)
        for bad in ["", "default", " 仕事", ".hidden", "a/b", "a:b", "a\nb", String(repeating: "長", count: 30)] {
            #expect(BrowserProfile.problem(withName: bad) != nil, "\(bad)")
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

    /// 読めない一覧を空として上書きすると、名前とサイトデータの対応が失われる。
    @Test func brokenRegistryIsNotOverwritten() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: file)
        #expect(throws: ProfileError.self) { try ProfileRegistry.load(from: file) }

        let switcher = ProfileSwitcher(current: BrowserProfile.defaultName, registryURL: file)
        #expect(throws: (any Error).self) { try switcher.create("仕事") }
        #expect(try Data(contentsOf: file) == Data("{".utf8))
    }

    @Test func switcherListsDefaultThenRegistered() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let switcher = ProfileSwitcher(current: BrowserProfile.defaultName, registryURL: file)
        #expect(switcher.names == [BrowserProfile.defaultName])
        #expect(try switcher.create(" 仕事 ") == "仕事", "前後の空白は落とす")
        #expect(switcher.names == [BrowserProfile.defaultName, "仕事"])

        // 別の実体が足した分は、読み直すと出る。こちらで足しても消さない。
        var registry = try ProfileRegistry.load(from: file)
        try registry.add("趣味")
        try registry.save(to: file)
        switcher.reload()
        #expect(switcher.names == [BrowserProfile.defaultName, "仕事", "趣味"])
        _ = try switcher.create("買い物")
        #expect(try ProfileRegistry.load(from: file).profiles.map(\.name) == ["仕事", "趣味", "買い物"])
    }

    /// 使い捨ての実体は、登録した一覧を見せず、書き換えもしない。
    @Test func temporarySwitcherDoesNotTouchRegistry() throws {
        let switcher = ProfileSwitcher(current: "dev", registryURL: nil)
        #expect(switcher.names == ["dev"])
        _ = try switcher.create("仕事")
        #expect(switcher.names == ["dev", "仕事"])
        #expect(throws: ProfileError.self) { try switcher.create("仕事") }
        #expect(throws: ProfileError.self) { try switcher.create("a/b") }
    }

    @Test func switchingToItselfStays() async throws {
        let switcher = ProfileSwitcher(current: "dev", registryURL: nil)
        #expect(try await switcher.switchTo("dev") == .alreadyHere)
        await #expect(throws: ProfileError.self) { try await switcher.switchTo("ない") }
    }

    @Test func profileCommands() async {
        let service = ControlService(store: TabStore(factory: PageFactory(dataStore: .nonPersistent())),
                                     profiles: ProfileSwitcher(current: "dev", registryURL: nil))
        func run(_ args: String...) async -> ControlResponse {
            await service.respond(to: ControlRequest(args: args))
        }

        var response = await run("profiles")
        #expect(response.ok)
        #expect(response.output.contains("* dev"))

        response = await run("profile-new", "仕事")
        #expect(response.ok, "\(response.output)")
        #expect(response.output.contains("  仕事"))

        response = await run("profile-new", "a/b")
        #expect(!response.ok)
        #expect(response.output.contains("使えない名前"))

        response = await run("profile-open", "dev")
        #expect(response.output == "already here: dev")

        response = await run("pid")
        #expect(response.output == "pid \(getpid())")
    }
}
