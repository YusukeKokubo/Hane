import Foundation
import Testing
@testable import Browser

@Suite struct AddressResolverTests {
    @Test(arguments: [
        ("https://example.com/a?b=1", "https://example.com/a?b=1"),
        ("  http://example.com  ", "http://example.com"),
        ("example.com", "https://example.com"),
        ("example.com/path?q=1#top", "https://example.com/path?q=1#top"),
        ("sub.example.co.jp:8443/x", "https://sub.example.co.jp:8443/x"),
        ("localhost", "http://localhost"),
        ("localhost:3000/api", "http://localhost:3000/api"),
        ("192.168.1.10:8080", "http://192.168.1.10:8080"),
        ("about:blank", "about:blank"),
        ("file:///tmp/a.html", "file:///tmp/a.html"),
        ("data:text/html,<b>a b</b>", "data:text/html,%3Cb%3Ea%20b%3C/b%3E"),
    ])
    func opensAsURL(input: String, expected: String) {
        #expect(AddressResolver.resolve(input)?.absoluteString == expected)
    }

    @Test(arguments: [
        "swift concurrency",
        "三河弁 とは",
        "3.14",
        "hello",
        "foo:bar",
        "what is example.com",
        "1.2.3.4.5",
    ])
    func fallsBackToSearch(input: String) throws {
        let url = try #require(AddressResolver.resolve(input))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.absoluteString.hasPrefix(BrowserSettings.searchEndpoint))
        #expect(components.queryItems?.first?.value == input)
    }

    @Test func emptyInputIsIgnored() {
        #expect(AddressResolver.resolve("   ") == nil)
    }
}
