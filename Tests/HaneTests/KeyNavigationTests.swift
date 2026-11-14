import AppKit
import Foundation
import Testing
import WebKit
@testable import Hane

/// 文字のキーでページを操作する（`KeyNavigation`）。
@MainActor
@Suite(.serialized) struct KeyNavigationTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "key-navigation-\(UUID().uuidString)")
    private let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()))

    init() {
        _ = NSApplication.shared
    }

    @Test func excludedSitesIncludeSubdomains() {
        var settings = UserSettings()
        settings.keyNavigationExcludedSites = ["mail.google.com", "example.org"]
        let policy = KeyNavigation.Policy(settings)
        #expect(!policy.allows(host: "mail.google.com"))
        #expect(!policy.allows(host: "Mail.Google.com"))
        #expect(!policy.allows(host: "www.example.org"))
        #expect(policy.allows(host: "notmail.google.com"))
        #expect(policy.allows(host: "docs.google.com"))
        #expect(policy.allows(host: ""), "file:// のページ")
        settings.usesKeyNavigation = false
        #expect(!KeyNavigation.Policy(settings).allows(host: "docs.google.com"))
    }

    @Test func sitesCanBeTypedAsURLs() {
        #expect(KeyNavigation.site(from: " https://Calendar.Google.com/calendar/u/0/r ") == "calendar.google.com")
        #expect(KeyNavigation.site(from: "mail.google.com/mail") == "mail.google.com")
        #expect(KeyNavigation.site(from: "*.example.com") == "example.com")
        #expect(KeyNavigation.site(from: "  ") == nil)
        #expect(KeyNavigation.site(from: "a b") == nil)
    }

    /// メニューから戻すときは、親のドメインで外したものも一覧から外す。
    @Test func menuTogglesTheCurrentSite() {
        let before = KeyNavigation.policy
        defer { KeyNavigation.policy = before }
        let settings = SettingsStore()
        settings.removeKeyNavigationExclusion("mail.google.com")
        settings.excludeFromKeyNavigation("google.com")
        #expect(settings.isExcludedFromKeyNavigation("mail.google.com"))
        #expect(!KeyNavigation.policy.allows(host: "mail.google.com"))

        settings.setKeyNavigation(excluded: false, on: "mail.google.com")
        #expect(!settings.isExcludedFromKeyNavigation("mail.google.com"))
        #expect(!settings.keyNavigationExcludedSites.contains("google.com"))
        settings.setKeyNavigation(excluded: true, on: "www.example.com")
        #expect(settings.keyNavigationExcludedSites.last == "www.example.com")
    }

    // MARK: ページの中

    private func open(_ html: String) async throws -> (Tab, NSWindow) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "page-\(UUID().uuidString).html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        let tab = store.open(URLRequest(url: url))
        for _ in 0..<150 where tab.page?.url != url || tab.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        let page = try #require(tab.page)
        // 本物のキーとして届けるため、窓に載せてキーを受ける部品にする。
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        page.webView.frame = window.contentLayoutRect
        window.contentView = page.webView
        // 先にキーを受ける部品にしておく。前に出してからだと、AppKit が Tab で入ったのと同じ扱いで
        // Web ビューへフォーカスを送り、WebKit がページの最初の入力欄にフォーカスを入れてしまう。
        window.makeFirstResponder(page.webView)
        window.makeKeyAndOrderFront(nil)
        // アプリが使ってよいと答えるまで待つ。
        try await Task.sleep(for: .milliseconds(200))
        return (tab, window)
    }

    private func press(_ characters: String, in window: NSWindow, shift: Bool = false) async throws {
        for character in characters {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                try send(type, character, in: window, shift: shift)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func send(_ type: NSEvent.EventType, _ character: Character, in window: NSWindow, shift: Bool = false) throws {
        let text = String(character)
        let event = try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: shift || character.isUppercase ? .shift : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: Self.keyCodes[character.lowercased()] ?? 0))
        window.sendEvent(event)
    }

    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "j": 38, "k": 40, "l": 37, "x": 7, "y": 16, "u": 32, "i": 34,
    ]

    private func evaluate(_ tab: Tab, _ script: String) async throws -> Any? {
        try await tab.page?.callJavaScript(script, arguments: [:], contentWorld: .page)
    }

    private func waitFor(_ tab: Tab, _ condition: String) async throws -> Bool {
        for _ in 0..<50 {
            if try await evaluate(tab, "return \(condition)") as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static let tallPage = """
        <title>Tall</title><style>body { margin: 0 } #space { height: 5000px }</style>
        <input id="field"><div id="space"></div>
        """

    @Test func lettersScrollThePageButNotWhileTyping() async throws {
        let (tab, window) = try await open(Self.tallPage)
        defer { window.close() }

        try await press("j", in: window)
        #expect(try await waitFor(tab, "scrollY > 0"))
        try await press("G", in: window)
        #expect(try await waitFor(tab, "scrollY > 4000"))
        try await press("gg", in: window)
        #expect(try await waitFor(tab, "scrollY === 0"))

        _ = try await evaluate(tab, "document.getElementById('field').focus()")
        try await press("jj", in: window)
        #expect(try await evaluate(tab, "return document.getElementById('field').value") as? String == "jj")
        #expect(try await evaluate(tab, "return scrollY") as? Int == 0)
    }

    /// 押しっぱなしの間は流れ続け、離せば止まる。
    @Test func holdingAKeyKeepsScrollingUntilReleased() async throws {
        let (tab, window) = try await open(Self.tallPage)
        defer { window.close() }

        try send(.keyDown, "j", in: window)
        try await Task.sleep(for: .milliseconds(600))
        try send(.keyUp, "j", in: window)
        let released = try await evaluate(tab, "return scrollY") as? Double ?? 0
        // 一歩（70）を超えて流れている。
        #expect(released > 200)
        try await Task.sleep(for: .milliseconds(300))
        let settled = try await evaluate(tab, "return scrollY") as? Double
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await evaluate(tab, "return scrollY") as? Double == settled)
    }

    /// 合成したキーには応じない。ページが勝手にタブを閉じたりできないように。
    @Test func syntheticKeysAreIgnored() async throws {
        let (tab, window) = try await open(Self.tallPage)
        defer { window.close() }
        let tabs = store.tabs.count
        _ = try await evaluate(tab, """
            for (const key of ['j', 'x']) document.body.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }));
            """)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await evaluate(tab, "return scrollY") as? Int == 0)
        #expect(store.tabs.count == tabs)
    }

    @Test func hintsClickTheChosenLink() async throws {
        let (tab, window) = try await open("""
            <title>Hints</title>
            <button id="a" onclick="document.title = 'A'">A</button>
            <button id="b" onclick="document.title = 'B'">B</button>
            """)
        defer { window.close() }
        // 印は s, a, d… の順に付く。
        try await press("f", in: window)
        try await press("a", in: window)
        #expect(try await waitFor(tab, "document.title === 'B'"))
    }

    @Test func browserCommandsReachTheTabStore() async throws {
        let (tab, window) = try await open(#"<title>Links</title><a href="https://example.com/next">next</a>"#)
        defer { window.close() }
        let before = store.tabs.count
        try await press("F", in: window)
        try await press("s", in: window)
        for _ in 0..<50 where store.tabs.count == before { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.tabs.count == before + 1)
        #expect(store.selectedID == tab.id, "裏で開く")

        // 移った先は窓に載っていないので、戻るのは選択を直に戻して確かめる。
        try await press("K", in: window)
        for _ in 0..<50 where store.selectedID == tab.id { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.selectedID != tab.id)
        store.selectedID = tab.id
        try await press("J", in: window)
        for _ in 0..<50 where store.selectedID == tab.id { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.selectedID != tab.id)
        store.selectedID = tab.id

        try await press("x", in: window)
        for _ in 0..<50 where store.tabs.contains(where: { $0 === tab }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.tabs.contains { $0 === tab })
    }

    /// 外したサイトの設定は、開いているページにもその場で効く。
    @Test func turningOffTakesEffectImmediately() async throws {
        let before = KeyNavigation.policy
        defer { KeyNavigation.policy = before }
        let (tab, window) = try await open(Self.tallPage)
        defer { window.close() }
        var settings = UserSettings()
        settings.usesKeyNavigation = false
        KeyNavigation.policy = KeyNavigation.Policy(settings)
        try await Task.sleep(for: .milliseconds(100))
        try await press("j", in: window)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await evaluate(tab, "return scrollY") as? Int == 0)

        KeyNavigation.policy = KeyNavigation.Policy(UserSettings())
        try await Task.sleep(for: .milliseconds(100))
        try await press("j", in: window)
        #expect(try await waitFor(tab, "scrollY > 0"), "戻せばまた効く")
    }
}
