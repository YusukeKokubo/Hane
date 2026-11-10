import Foundation

/// アドレスバーの入力を、開くべきURLに変換する。
enum AddressResolver {
    private static let directSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob"]

    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = explicitURL(text) { return url }
        if let url = hostLikeURL(text) { return url }
        return searchURL(for: text)
    }

    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: BrowserSettings.searchEndpoint)
        components?.queryItems = [URLQueryItem(name: BrowserSettings.searchQueryName, value: query)]
        return components?.url
    }

    /// `https://…` のようにスキームまで書かれた入力。
    private static func explicitURL(_ text: String) -> URL? {
        // data: は中身に空白を含みうるので、空白があっても検索に回さない。
        if text.lowercased().hasPrefix("data:") { return URL(string: text) }
        guard !text.contains(" "),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              directSchemes.contains(scheme)
        else { return nil }
        // "localhost:3000" は scheme が "localhost" と解釈されるので、ここには来ない。
        if scheme == "http" || scheme == "https" {
            return url.host() == nil ? nil : url
        }
        return url
    }

    /// `example.com/path` や `localhost:3000` のようにスキームを省いた入力。
    private static func hostLikeURL(_ text: String) -> URL? {
        guard !text.contains(" ") else { return nil }

        let authority = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let host: Substring
        if let colon = authority.lastIndex(of: ":") {
            let port = authority[authority.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
            host = authority[..<colon]
        } else {
            host = authority
        }
        guard !host.isEmpty else { return nil }

        let isLocal = host == "localhost" || isIPv4(host)
        guard isLocal || looksLikeDomain(host) else { return nil }

        let scheme = isLocal ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(text)"), url.host() != nil else { return nil }
        return url
    }

    private static func isIPv4(_ host: Substring) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) && Int(part)! <= 255
        }
    }

    private static func looksLikeDomain(_ host: Substring) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        // 末尾ラベルが英字2文字以上なら、ドメイン名とみなす（"3.14" などは検索に回す）。
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }
}
