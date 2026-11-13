import Foundation

/// Adblock Plus 形式のフィルタリスト（EasyList など）を、WebKit のコンテンツブロッカーのルールに変える。
///
/// WebKit で表せない書き方（正規表現、uBlock や AdGuard の拡張、ページの書き換えなど）は
/// 読み飛ばす。ひとつでも WebKit が受け付けないルールが混じるとリスト全体のコンパイルに
/// 失敗するので、自信のないものは訳さずに捨てる方へ倒している。
enum FilterList {
    /// 変換の版。訳し方を変えたら上げる。コンパイル済みのリストを作り直す合図になる。
    static let version = 1

    struct Conversion: Sendable {
        var rules: [ContentRule] = []
        /// 訳せずに捨てたフィルタの数。
        var skipped = 0
    }

    /// 複数のリストをまとめて1つのルール列にする。
    ///
    /// 要素を隠すルール、通信を止めるルール、例外の順に並べる。WebKit の例外
    /// （`ignore-previous-rules`）は同じリストで自分より前にあるルールしか取り消せないため。
    ///
    /// WebKit は1リストに `limit` 件までしか受け付けない。超えたら、種類の指定がないフィルタを
    /// 子フレームにも効かせるために足した複製を落として収める。広告のフレームの中身は
    /// スクリプトや画像の側でたいてい止まるので、失うものがいちばん少ない。
    static func convert(_ lists: [String], limit: Int = 150_000) -> Conversion {
        var conversion = convertAll(lists)
        if conversion.rules.count > limit {
            let before = conversion.rules.count
            conversion.rules.removeAll { $0.trigger.loadContext != nil }
            conversion.skipped += before - conversion.rules.count
        }
        return conversion
    }

    private static func convertAll(_ lists: [String]) -> Conversion {
        var hides: [ContentRule] = []
        var blocks: [ContentRule] = []
        var exceptions: [ContentRule] = []
        var skipped = 0
        for list in lists {
            for line in list.split(whereSeparator: \.isNewline) {
                switch parse(line.trimmingCharacters(in: .whitespaces)) {
                case .ignored: break
                case .skipped: skipped += 1
                case .hide(let rule): hides.append(rule)
                case .block(let rules): blocks += rules
                case .exception(let rules): exceptions += rules
                }
            }
        }
        return Conversion(rules: hides + blocks + exceptions, skipped: skipped)
    }

    enum Parsed: Equatable {
        /// 空行や注釈。
        case ignored
        /// フィルタではあるが訳せなかった。
        case skipped
        case hide(ContentRule)
        case block([ContentRule])
        case exception([ContentRule])
    }

    static func parse(_ line: String) -> Parsed {
        if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return .ignored }
        // AdGuard の HTML の書き換え。通信のフィルタと取り違えないよう先に除く。
        if line.contains("$$") || line.contains("$@$") { return .skipped }
        if let cosmetic = parseCosmetic(line) { return cosmetic }
        return parseNetwork(line)
    }

    // MARK: 要素を隠すフィルタ

    /// `ドメイン##セレクタ` の形なら訳した結果を、通信のフィルタなら `nil` を返す。
    private static func parseCosmetic(_ line: String) -> Parsed? {
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let rest = line[hash...]
        // 例外（#@#）や拡張（#?# #$# #%#）は WebKit で表せないので捨てる。
        let separators = ["#@?#", "#@$#", "#@%#", "#@#", "#?#", "#$#", "#%#"]
        if separators.contains(where: rest.hasPrefix) { return .skipped }
        guard rest.hasPrefix("##") else { return nil }

        let selector = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard isSupported(selector: selector) else { return .skipped }
        let domainPart = line[..<hash]
        if domainPart.isEmpty {
            return .hide(.hide(selector, on: ContentRule.Trigger(urlFilter: ContentRule.Trigger.anyURL)))
        }
        guard let domains = parseDomains(domainPart.split(separator: ","), requireValid: true),
              let trigger = domains.trigger(urlFilter: ContentRule.Trigger.anyURL)
        else { return .skipped }
        return .hide(.hide(selector, on: trigger))
    }

    /// ブラウザのCSSが解釈できないセレクタ（uBlock や AdGuard の独自の疑似クラス）を除く。
    private static func isSupported(selector: String) -> Bool {
        guard !selector.isEmpty, selector.allSatisfy(\.isASCII),
              !selector.hasPrefix("+js("), !selector.hasPrefix("^")
        else { return false }
        let extensions = [
            ":-abp-", ":contains(", ":has-text(", ":upward(", ":xpath(", ":remove(", ":style(",
            ":matches-css", ":matches-path(", ":matches-attr(", ":matches-property(", ":min-text-length(",
            ":watch-attr(", ":others(", ":nth-ancestor(", ":if(", ":if-not(", " {",
        ]
        return !extensions.contains(where: selector.contains)
    }

    // MARK: 通信のフィルタ

    /// Adblock Plus の資源の種類と、WebKit の `resource-type` の対応。
    /// 子フレーム（subdocument）とページ本体（document）は別に扱う。
    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font",
        "media": "media", "xmlhttprequest": "fetch", "websocket": "websocket", "ping": "ping", "other": "other",
    ]
    private static let typeAliases = ["xhr": "xmlhttprequest", "css": "stylesheet", "frame": "subdocument", "doc": "document"]
    /// WebKit に相当がない種類。これだけを狙ったフィルタは訳さない。
    private static let unsupportedTypes: Set<String> = ["popup", "object", "object-subrequest"]
    /// 種類の指定がないときに狙う範囲。Adblock Plus と同じく、ページ本体は含めない。
    /// ページ本体まで止めると、アドレスに `/ads/` を含むだけの普通のページが開けなくなる。
    private static let defaultTypes = Set(resourceTypes.keys).union(["subdocument"])

    private static func parseNetwork(_ line: String) -> Parsed {
        var body = Substring(line)
        let isException = body.hasPrefix("@@")
        if isException { body = body.dropFirst(2) }

        var pattern = body
        var options: [Substring] = []
        if let dollar = body.lastIndex(of: "$") {
            pattern = body[..<dollar]
            options = body[body.index(after: dollar)...].split(separator: ",")
        }
        // 正規表現のフィルタ。WebKit の正規表現は機能が足りず、確実には訳せない。
        if pattern.count > 1, pattern.hasPrefix("/"), pattern.hasSuffix("/") { return .skipped }

        var types = Set<String>()
        var excludedTypes = Set<String>()
        var loadType: String?
        var caseSensitive = false
        var domains = Domains()
        for raw in options {
            let negated = raw.hasPrefix("~")
            let option = (negated ? raw.dropFirst() : raw).lowercased()
            let (name, value) = option.split(separator: "=", maxSplits: 1).map(String.init).splitPair
            switch typeAliases[name] ?? name {
            case "third-party", "3p":
                loadType = negated ? "first-party" : "third-party"
            case "first-party", "1p":
                loadType = negated ? "third-party" : "first-party"
            case "match-case":
                caseSensitive = true
            case "important":
                break
            case "domain", "from":
                guard let parsed = parseDomains(value.split(separator: "|"), requireValid: false) else { return .skipped }
                domains = parsed
            case let type where resourceTypes[type] != nil || unsupportedTypes.contains(type)
                || ["subdocument", "document", "all"].contains(type):
                if negated { excludedTypes.insert(type) } else { types.insert(type) }
            default:
                // csp や redirect など、通信を止める以外の働きをするもの。
                return .skipped
            }
        }

        var wanted = types.isEmpty ? defaultTypes : types
        if wanted.contains("all") { wanted = defaultTypes.union(["document"]) }
        wanted.subtract(excludedTypes)

        if isException && wanted.contains("document") {
            return siteException(pattern: pattern, domains: domains)
        }
        guard let urlFilter = urlFilter(from: pattern) else { return .skipped }
        var base = ContentRule.Trigger(urlFilter: urlFilter)
        base.urlFilterIsCaseSensitive = caseSensitive ? true : nil
        base.loadType = loadType.map { [$0] }
        guard let trigger = domains.trigger(base) else { return .skipped }

        var triggers: [ContentRule.Trigger] = []
        let others = wanted.compactMap { resourceTypes[$0] }.sorted()
        if !others.isEmpty {
            var t = trigger
            t.resourceType = others
            triggers.append(t)
        }
        if wanted.contains("document") {
            var t = trigger
            t.resourceType = ["document"]
            triggers.append(t)
        } else if wanted.contains("subdocument") {
            var t = trigger
            t.resourceType = ["document"]
            t.loadContext = ["child-frame"]
            triggers.append(t)
        }
        guard !triggers.isEmpty else { return .skipped }
        let action = ContentRule.Action(type: isException ? .ignorePreviousRules : .block)
        let rules = triggers.map { ContentRule(trigger: $0, action: action) }
        return isException ? .exception(rules) : .block(rules)
    }

    /// `@@||example.com^$document` のような、サイト全体を対象から外す例外。
    ///
    /// WebKit の例外は合致した読み込みひとつにしか効かないので、ページ本体のアドレスで
    /// 合わせても中の資源は止まったままになる。そこで「そのサイトのページでのすべての読み込み」
    /// として書き直す。サイトを名指ししていない形は訳せない。
    private static func siteException(pattern: Substring, domains: Domains) -> Parsed {
        guard pattern.hasPrefix("||"), domains.isEmpty else { return .skipped }
        var host = pattern.dropFirst(2)
        while let last = host.last, "^/|".contains(last) { host = host.dropLast() }
        guard isValidDomain(host) else { return .skipped }
        let trigger = ContentRule.Trigger.onSite(String(host))
        return .exception([ContentRule(trigger: trigger, action: ContentRule.Action(type: .ignorePreviousRules))])
    }

    /// Adblock Plus のアドレスの型を、WebKit の `url-filter` の正規表現にする。
    static func urlFilter(from pattern: Substring) -> String? {
        guard pattern.allSatisfy(\.isASCII) else { return nil }
        var rest = pattern
        var result = ""
        if rest.hasPrefix("||") {
            // スキームのあと、ホスト名の先頭か「.」の直後から始まる。
            result = "^[^:]+://+([^/]+\\.)?"
            rest = rest.dropFirst(2)
        } else if rest.hasPrefix("|") {
            result = "^"
            rest = rest.dropFirst()
        }
        var suffix = ""
        if rest.hasSuffix("|") {
            suffix = "$"
            rest = rest.dropLast()
        } else if rest.hasSuffix("^"), rest.contains("/") {
            // 末尾の区切りは「区切り文字か、アドレスの終わり」の意味。WebKit には「または」が
            // ないので、区切りから先をまるごと省略できる形にする。ホスト名だけの型は
            // 後ろに必ず「/」か「:」が続くので、普通の区切りのままでよい。
            suffix = "([/:?=&].*)?$"
            rest = rest.dropLast()
        }
        for character in rest {
            switch character {
            case "*": result += ".*"
            case "^": result += "[/:?=&]"
            case "|": return nil
            default: result += ContentRule.Trigger.escape(String(character))
            }
        }
        if result.isEmpty && suffix.isEmpty { return ContentRule.Trigger.anyURL }
        return result + suffix
    }

    // MARK: ドメイン

    struct Domains {
        var included: [String] = []
        var excluded: [String] = []

        var isEmpty: Bool { included.isEmpty && excluded.isEmpty }

        func trigger(urlFilter: String) -> ContentRule.Trigger? {
            trigger(ContentRule.Trigger(urlFilter: urlFilter))
        }

        /// 条件にドメインを足す。WebKit は if-domain と unless-domain を同時に持てないので、
        /// 両方あるときは対象のドメインだけを残す（除外したい下位ドメインでも効いてしまうが、
        /// 捨てるよりは効く方がよい）。
        func trigger(_ base: ContentRule.Trigger) -> ContentRule.Trigger? {
            var trigger = base
            if !included.isEmpty {
                trigger.ifDomain = included.map { "*" + $0 }
            } else if !excluded.isEmpty {
                trigger.unlessDomain = excluded.map { "*" + $0 }
            }
            return trigger
        }
    }

    /// `example.com,~ads.example.com` のようなドメインの並びを読む。
    ///
    /// WebKit で表せない名前（`example.*` のようなワイルドカードや正規表現）は捨てる。
    /// 対象のドメインを全部捨てると、狙いより広く効いてしまうので、そのときは `nil` を返す。
    /// `requireValid` なら、ひとつでも表せない名前があれば `nil` にする。
    private static func parseDomains(_ entries: [Substring], requireValid: Bool) -> Domains? {
        var domains = Domains()
        var droppedIncluded = false
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            let negated = trimmed.hasPrefix("~")
            let name = (negated ? String(trimmed.dropFirst()) : trimmed).lowercased()
            guard isValidDomain(Substring(name)) else {
                if requireValid { return nil }
                if !negated { droppedIncluded = true }
                continue
            }
            if negated { domains.excluded.append(name) } else { domains.included.append(name) }
        }
        if droppedIncluded && domains.included.isEmpty { return nil }
        return domains
    }

    private static func isValidDomain(_ name: Substring) -> Bool {
        !name.isEmpty && name.first != "." && name.last != "."
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

private extension Array where Element == String {
    /// `name=value` を分けた結果。`=` がなければ値は空。
    var splitPair: (String, String) {
        (first ?? "", count > 1 ? self[1] : "")
    }
}
