import Foundation
import Testing
import WebKit
@testable import Hane

/// 1Password のログインの読み方、ページへの合わせ方、入力欄への入れ方。
@MainActor
@Suite struct PasswordFillTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "password-fill-\(UUID().uuidString)")
    private let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()))
    private let credentials = Credentials(username: "alice@example.com", password: "s3cret", oneTimeCode: "123456")

    @Test func readsTheCLIOutput() throws {
        let list = Data(#"""
            [{"id":"a1","title":"GitHub","additional_information":"alice","urls":[{"label":"website","primary":true,"href":"https://www.GitHub.com/login"}]},
             {"id":"b2","title":"No URL"},
             {"id":"c3","title":"Bare","urls":[{"href":"example.org"}]}]
            """#.utf8)
        let items = try JSONDecoder().decode([LoginItem].self, from: list)
        #expect(items.map(\.hosts) == [["github.com"], [], ["example.org"]], "小文字にして www. を外す。スキームなしでも読む")
        #expect(items[0].username == "alice")

        let item = Data(#"""
            {"id":"a1","fields":[
              {"id":"username","type":"STRING","purpose":"USERNAME","label":"username","value":"alice"},
              {"id":"password","type":"CONCEALED","purpose":"PASSWORD","label":"password","value":"pw"},
              {"id":"x","type":"OTP","label":"one-time password","value":"otpauth://totp/x?secret=ABC","totp":"654321"}]}
            """#.utf8)
        let read = try JSONDecoder().decode(Credentials.self, from: item)
        #expect(read.username == "alice")
        #expect(read.password == "pw")
        #expect(read.oneTimeCode == "654321")
    }

    @Test func matchesThePageHostAndItsSubdomains() {
        func item(_ id: String, _ hosts: [String]) -> LoginItem {
            LoginItem(id: id, title: id, username: "", hosts: hosts)
        }
        let parent = item("parent", ["google.com"])
        let exact = item("exact", ["accounts.google.com"])
        let child = item("child", ["mail.accounts.google.com"])
        let other = item("other", ["evilgoogle.com"])
        let suffix = item("suffix", ["com"])
        let all = [parent, exact, child, other, suffix]

        #expect(LoginItem.candidates(all, for: "accounts.google.com").map(\.id) == ["exact", "parent"],
                "そのまま合うものが先。サブドメインのログインを親のページには出さない")
        #expect(LoginItem.candidates(all, for: "www.google.com").map(\.id) == ["parent"])
        #expect(LoginItem.candidates(all, for: "example.com").isEmpty, "一段だけのものはどのページにも合わせない")
    }

    @Test func fillsTheUsernameBeforeThePassword() async throws {
        let page = try await open("""
            <input id="search" type="search">
            <form>
              <input id="name" type="email">
              <input id="other" type="text">
              <input id="pw" type="password">
            </form>
            """)
        #expect(try await fill(page) == ["username", "password"])
        #expect(try await value("other", in: page) == "alice@example.com", "パスワード欄の手前にある最後の文字の欄")
        #expect(try await value("name", in: page) == "")
        #expect(try await value("pw", in: page) == "s3cret")
        #expect(try await value("search", in: page) == "")
    }

    @Test func prefersTheFocusedFieldAndSkipsHiddenOnes() async throws {
        let page = try await open("""
            <form>
              <input id="trap" type="password" style="display:none">
              <input id="name" type="text" autofocus>
              <input id="nick" type="text">
              <input id="pw" type="password">
            </form>
            <script>document.getElementById("name").focus()</script>
            """)
        #expect(try await fill(page) == ["username", "password"])
        #expect(try await value("name", in: page) == "alice@example.com")
        #expect(try await value("nick", in: page) == "")
        #expect(try await value("trap", in: page) == "", "見えない欄には入れない")
        #expect(try await value("pw", in: page) == "s3cret")
    }

    /// ユーザー名だけ先に聞くページと、ワンタイムコードを聞くページ。
    @Test func fillsStepByStepPages() async throws {
        let first = try await open(#"<input id="q" type="text" name="q"><input id="user" type="text" name="username">"#)
        #expect(try await fill(first) == ["username"])
        #expect(try await value("user", in: first) == "alice@example.com")
        #expect(try await value("q", in: first) == "")

        let code = try await open(#"<input id="otp" type="text" autocomplete="one-time-code">"#, name: "code.html")
        #expect(try await fill(code) == ["code"])
        #expect(try await value("otp", in: code) == "123456")
    }

    /// ページの側の `input` の見張り（React など）が、値の変化に気づける。
    @Test func pageListenersSeeTheChange() async throws {
        let page = try await open("""
            <input id="name" type="email"><input id="pw" type="password">
            <script>
              window.seen = [];
              document.addEventListener("input", e => seen.push(e.target.id + "=" + e.target.value));
            </script>
            """)
        _ = try await fill(page)
        let seen = try await page.callJavaScript("return seen", arguments: [:], contentWorld: .page) as? [String]
        #expect(seen == ["name=alice@example.com", "pw=s3cret"])
    }

    @Test func doesNothingAfterThePageMoved() async throws {
        let page = try await open(#"<input id="name" type="email"><input id="pw" type="password">"#)
        let elsewhere = try #require(URL(string: "https://elsewhere.example/"))
        #expect(try await PasswordFill.fill(credentials, into: page, at: elsewhere) == [])
        #expect(try await value("pw", in: page) == "")
    }

    @Test func refusesPagesWithoutAHost() async throws {
        _ = try await open("<p>")
        let fill = PasswordFill(source: FixedLogins())
        fill.start(on: store.selected)
        #expect(fill.state == .failed("このページにはログインを入れられません。"))
    }

    // MARK: 手伝い

    private struct FixedLogins: LoginSource {
        func logins() async throws -> [LoginItem] { [] }
        func credentials(for item: LoginItem) async throws -> Credentials { Credentials() }
    }

    private func open(_ body: String, name: String = "login.html") async throws -> Page {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try "<!doctype html><title>Login</title>\(body)".write(to: url, atomically: true, encoding: .utf8)
        let tab = try #require(store.selected)
        tab.open(url.absoluteString)
        for _ in 0..<150 where tab.page?.url != url || tab.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        let page = try #require(tab.page)
        try #require(page.url == url && !tab.isLoading)
        return page
    }

    private func fill(_ page: Page) async throws -> [String] {
        try await PasswordFill.fill(credentials, into: page, at: try #require(page.url))
    }

    private func value(_ id: String, in page: Page) async throws -> String? {
        try await page.callJavaScript("return document.getElementById(id).value", arguments: ["id": id], contentWorld: .page) as? String
    }
}
