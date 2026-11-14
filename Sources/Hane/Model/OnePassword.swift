import Foundation

/// ログインの出どころ。普段は 1Password の CLI で、テストでは手で作った一覧に差し替える。
protocol LoginSource: Sendable {
    /// 中身（パスワード）を含まない一覧。
    func logins() async throws -> [LoginItem]
    func credentials(for item: LoginItem) async throws -> Credentials
}

/// 1Password のログイン一件。一覧に出す分だけで、パスワードは持たない。
struct LoginItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// 一覧で見分けるためのユーザー名。1Password が一覧に添えるもの。
    let username: String
    /// 登録してあるアドレスのホスト。小文字で、先頭の `www.` は外してある。
    let hosts: [String]
    /// どの 1Password アカウントのものか（`account_uuid`）。中身を尋ねるときに要る。
    var account = ""
    /// 一覧で見分けるためのアカウントの名前（`my.1password.com` など）。
    var accountName = ""

    /// ページのホストに合うものだけを、ホストがそのまま合うものを先にして並べる。
    /// 登録したホストのサブドメインのページにも合わせる（`google.com` のログインを `accounts.google.com` で）。
    /// 逆向き（登録したのがサブドメインで、ページが親）は合わせない。
    static func candidates(_ items: [LoginItem], for pageHost: String) -> [LoginItem] {
        let host = normalize(pageHost)
        func rank(_ item: LoginItem) -> Int? {
            if item.hosts.contains(host) { return 0 }
            // `com` のような一段だけのものは、どのページにも合ってしまうので外す。
            if item.hosts.contains(where: { $0.contains(".") && host.hasSuffix("." + $0) }) { return 1 }
            return nil
        }
        let ranked: [(item: LoginItem, rank: Int)] = items.compactMap { item in
            guard let rank = rank(item) else { return nil }
            return (item, rank)
        }
        return ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.item.title.localizedStandardCompare(b.item.title) == .orderedAscending
        }.map(\.item)
    }

    static func normalize(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension LoginItem: Decodable {
    private enum Keys: String, CodingKey {
        case id, title, urls
        case username = "additional_information"
    }

    private struct Link: Decodable {
        let href: String
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        let links = try container.decodeIfPresent([Link].self, forKey: .urls) ?? []
        hosts = links.compactMap { link in
            // 1Password には `github.com` のようにスキームなしで登録されているものもある。
            let url = link.href.contains("://") ? URL(string: link.href) : URL(string: "https://" + link.href)
            return url?.host().map(LoginItem.normalize)
        }
    }
}

/// 入れる中身。使い終えたら捨て、どこにも書かない。
struct Credentials: Sendable {
    /// 入れられる項目一つ。
    struct Field: Equatable, Sendable {
        /// どの欄に入れるかを覚えるときの名前。ユーザー名・パスワード・ワンタイムコードは決まった名前で、
        /// 自分で足した項目は見出しで呼ぶ（項目の ID はログインごとに違い、同じサイトの別のログインで使い回せないため）。
        let key: String
        /// メニューに出す名前。
        let label: String
        let value: String
    }

    static let usernameKey = "username"
    static let passwordKey = "password"
    static let oneTimeCodeKey = "one-time-code"

    var fields: [Field]

    init(fields: [Field] = []) {
        self.fields = fields
    }

    /// テストで手早く作るため。
    init(username: String, password: String, oneTimeCode: String? = nil) {
        fields = [
            Field(key: Self.usernameKey, label: "ユーザー名", value: username),
            Field(key: Self.passwordKey, label: "パスワード", value: password),
        ]
        if let oneTimeCode { fields.append(Field(key: Self.oneTimeCodeKey, label: "ワンタイムコード", value: oneTimeCode)) }
    }

    func value(for key: String) -> String? {
        fields.first { $0.key == key }?.value
    }

    var username: String { value(for: Self.usernameKey) ?? "" }
    var password: String { value(for: Self.passwordKey) ?? "" }
    /// 今のワンタイムコード。登録していなければ `nil`。
    var oneTimeCode: String? { value(for: Self.oneTimeCodeKey) }
}

extension Credentials: Decodable {
    private enum Keys: String, CodingKey { case fields }

    private struct Raw: Decodable {
        let id: String?
        let type: String?
        let purpose: String?
        let label: String?
        let value: String?
        let totp: String?
    }

    init(from decoder: any Decoder) throws {
        let raws = try decoder.container(keyedBy: Keys.self).decodeIfPresent([Raw].self, forKey: .fields) ?? []
        var fields: [Field] = []
        for raw in raws {
            let field: Field? = switch (raw.purpose, raw.type) {
            case ("USERNAME", _): raw.value.map { Field(key: Self.usernameKey, label: "ユーザー名", value: $0) }
            case ("PASSWORD", _): raw.value.map { Field(key: Self.passwordKey, label: "パスワード", value: $0) }
            case ("NOTES", _): nil
            // 値は otpauth の URI なので、今のコード（totp）を使う。
            case (_, "OTP"): raw.totp.map { Field(key: Self.oneTimeCodeKey, label: "ワンタイムコード", value: $0) }
            default:
                (raw.label ?? raw.id).flatMap { label in raw.value.map { Field(key: "label:" + label, label: label, value: $0) } }
            }
            // 同じ名前の項目が二つあれば、先のものを使う。
            if let field, !field.value.isEmpty, !fields.contains(where: { $0.key == field.key }) {
                fields.append(field)
            }
        }
        self.fields = fields
    }
}

/// 1Password の CLI（`op`）。尋ねるたびに起こし、答えたら終わる。
///
/// 解錠は 1Password 本体の「CLI と連携」に任せる（初めてと、しばらく使わなかった後に Touch ID を求められる）。
/// アプリは Finder や Raycast から起きると `PATH` に Homebrew が入らないので、置き場を決め打ちで探す。
struct OnePasswordCLI: LoginSource {
    static let candidates = ["/opt/homebrew/bin/op", "/usr/local/bin/op"]

    private struct Account: Decodable {
        let account_uuid: String
        let url: String
    }

    /// 1Password にアカウントがいくつもあると、`op` はどれか決めないと答えないので、全部に尋ねて合わせる。
    /// 鍵がかかっているなどで答えないアカウントがあっても、ほかのものが答えればそれで出す。
    func logins() async throws -> [LoginItem] {
        let accounts = try JSONDecoder().decode([Account].self, from: try await Self.run(["account", "list", "--format", "json"]))
        guard !accounts.isEmpty else { throw Failure.notConnected }
        let results = await withTaskGroup(of: Result<[LoginItem], any Error>.self) { group in
            for account in accounts {
                group.addTask {
                    do {
                        let data = try await Self.run([
                            "item", "list", "--categories", "Login", "--format", "json", "--account", account.account_uuid,
                        ])
                        return .success(try JSONDecoder().decode([LoginItem].self, from: data).map { item in
                            var item = item
                            item.account = account.account_uuid
                            item.accountName = account.url
                            return item
                        })
                    } catch {
                        return .failure(error)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let items = results.compactMap { try? $0.get() }
        if items.isEmpty, case .failure(let error)? = results.first { throw error }
        return items.flatMap(\.self)
    }

    func credentials(for item: LoginItem) async throws -> Credentials {
        var arguments = ["item", "get", item.id, "--reveal", "--format", "json"]
        if !item.account.isEmpty { arguments += ["--account", item.account] }
        return try JSONDecoder().decode(Credentials.self, from: try await Self.run(arguments))
    }

    enum Failure: LocalizedError {
        case missing
        case notConnected
        case failed(String)

        /// `op` の言う失敗を、こちらで手を打てるものとそうでないものに分ける。
        init(message: String) {
            self = message.contains("No accounts configured") ? .notConnected : .failed(message)
        }

        var errorDescription: String? {
            switch self {
            case .missing:
                "1Password CLI（op）が見つかりません。brew install 1password-cli で入れ、1Password の設定の「開発者」で CLI との連携を入れてください。"
            case .notConnected:
                "1Password とつながっていません。1Password の設定の「開発者」で「1Password CLI と連携」を入れてください。"
            case .failed(let message):
                message.isEmpty ? "1Password CLI が失敗しました。" : "1Password CLI: \(message)"
            }
        }
    }

    /// 解錠を待つと何秒も返らないので、Swift の並行処理の持ち場を塞がないよう、別のスレッドで待つ。
    private static func run(_ arguments: [String]) async throws -> Data {
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw Failure.missing
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(path, arguments) })
            }
        }
    }

    private static func runBlocking(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // 一覧は管の受け皿（64KB）を超えるので、終わりを待つ前に読み切る。
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        let message = try errors.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: cleaned(message)) }
        return data
    }

    /// `[ERROR] 2026/11/13 10:00:00 中身` の頭を外す。
    private static func cleaned(_ message: Data) -> String {
        var text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^\[ERROR\] \S+ \S+ "#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
    }
}
