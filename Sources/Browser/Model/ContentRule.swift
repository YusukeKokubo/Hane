import Foundation

/// WebKitのコンテンツブロッカーのルール1件。JSONにして `WKContentRuleListStore` でコンパイルする。
///
/// 書式は WebKit の「Creating a content blocker」の取り決めどおり。使わない項目は省く。
struct ContentRule: Codable, Equatable, Sendable {
    var trigger: Trigger
    var action: Action

    struct Trigger: Codable, Equatable, Sendable {
        var urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var resourceType: [String]?
        var loadType: [String]?
        var loadContext: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case loadContext = "load-context"
        }
    }

    struct Action: Codable, Equatable, Sendable {
        var type: Kind
        var selector: String?

        enum Kind: String, Codable, Sendable {
            case block
            case hide = "css-display-none"
            /// 同じリストでこれより前にあるルールを、合致した読み込みについて取り消す。
            case ignorePreviousRules = "ignore-previous-rules"
        }
    }

    static func hide(_ selector: String, on trigger: Trigger) -> ContentRule {
        ContentRule(trigger: trigger, action: Action(type: .hide, selector: selector))
    }

    static func encode(_ rules: [ContentRule]) throws -> String {
        let data = try JSONEncoder().encode(rules)
        return String(decoding: data, as: UTF8.self)
    }
}

extension ContentRule.Trigger {
    /// すべてのアドレスに合う `url-filter`。
    static let anyURL = ".*"

    /// サイトの中だけに効く条件。下位のドメインも含める。
    static func onSite(_ host: String) -> Self {
        Self(urlFilter: anyURL, ifDomain: ["*" + host.lowercased()])
    }

    /// `url-filter` で文字どおりに合わせるための書き換え。WebKit の正規表現は機能が限られ、
    /// `{}` や `|` も特別な意味に取られるので、記号はすべて逃がす。
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\.+*?()[]{}|^$".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
