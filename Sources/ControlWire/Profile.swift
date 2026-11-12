import Foundation

/// 環境変数 `BROWSER_PROFILE` で選ぶ、アプリの実体の区別。
///
/// 一つの実体は一つのプロファイルだけを受け持つ。Cookie などのサイトデータ、ブックマーク、閲覧履歴、
/// 閲覧状態はプロファイルごとに分かれ、操作用ソケットも別になる。
///
/// 指定がなければ普段使いの `default`。保存するのは `default` と、一覧（`ProfileRegistry`）に登録した名前だけで、
/// それ以外の名前（開発用の `dev` など）はCookieなども残さない使い捨てになる。
public enum BrowserProfile {
    public static let environmentKey = "BROWSER_PROFILE"
    /// `1` なら、一覧に登録した名前でも使い捨てにする。使い捨ての実体から別のプロファイルを起こすときに引き継ぎ、
    /// 開発用の実体から普段使いのデータに触れないようにする。
    public static let ephemeralKey = "BROWSER_EPHEMERAL"
    public static let defaultName = "default"

    public static let name: String = {
        guard let value = ProcessInfo.processInfo.environment[environmentKey],
              value == defaultName || problem(withName: value) == nil
        else { return defaultName }
        return value
    }()

    public static var isDefault: Bool { name == defaultName }

    /// 一覧に登録してあるこのプロファイル。起動した時点の一覧から引く。普段使いと使い捨てでは `nil`。
    public static let entry: ProfileRegistry.Entry? = {
        guard !isDefault, ProcessInfo.processInfo.environment[ephemeralKey] != "1" else { return nil }
        return (try? ProfileRegistry.load())?.entry(named: name)
    }()

    /// サイトデータやブックマークを保存するか。
    public static var isPersistent: Bool { isDefault || entry != nil }

    /// このプロファイルの持ち物（ブックマーク、閲覧履歴、閲覧状態など）を置く場所。使い捨てなら `nil`。
    public static var dataDirectory: URL? { isPersistent ? directory(for: name) : nil }

    /// プロファイルの置き場。`default` はプロファイルを分ける前からの場所のままにして、持ち物を移さずに済ませる。
    public static func directory(for name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Browser", directoryHint: .isDirectory)
        return name == defaultName ? base : base.appending(path: "profiles/\(name)", directoryHint: .isDirectory)
    }

    /// 名前として使えないなら、その理由。名前はそのままパスと環境変数に入るので、
    /// 区切り文字や制御文字を除き、操作用ソケットのパスが上限（104バイト）に収まる長さに限る。
    public static func problem(withName name: String) -> String? {
        if name.isEmpty { return "名前が空" }
        if name == defaultName { return "「\(defaultName)」は普段使いのプロファイルの名前" }
        if name != name.trimmingCharacters(in: .whitespacesAndNewlines) { return "前後に空白がある" }
        if name.hasPrefix(".") { return "「.」で始まる名前は使えない" }
        if name.unicodeScalars.contains(where: { $0 == "/" || $0 == ":" || CharacterSet.controlCharacters.contains($0) }) {
            return "「/」「:」や改行は使えない"
        }
        if ControlSocket.path(for: name).utf8.count >= 104 { return "名前が長すぎる" }
        return nil
    }
}

public struct ProfileError: LocalizedError, CustomStringConvertible {
    public let description: String

    public var errorDescription: String? { description }

    public init(_ description: String) {
        self.description = description
    }
}

/// 保存するプロファイルの一覧。普段使い（`default`）は含めない。
///
/// サイトデータの置き場は、WebKit が識別子（UUID）で分けて持つ。名前と識別子の対応をここに残す。
public struct ProfileRegistry: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        /// サイトデータの置き場（`WKWebsiteDataStore`）の識別子。
        public var dataStore: UUID
    }

    public var profiles: [Entry] = []

    public init() {}

    public static var fileURL: URL {
        BrowserProfile.directory(for: BrowserProfile.defaultName).appending(path: "profiles.json")
    }

    /// ファイルがなければ空の一覧。読めないときは投げる（空として上書きすると、サイトデータとの対応を失うため）。
    public static func load(from url: URL = fileURL) throws -> ProfileRegistry {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return ProfileRegistry() }
        do {
            return try JSONDecoder().decode(ProfileRegistry.self, from: Data(contentsOf: url))
        } catch {
            throw ProfileError("プロファイルの一覧（\(url.path(percentEncoded: false))）を読めない: \(error)")
        }
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func entry(named name: String) -> Entry? {
        profiles.first { $0.name == name }
    }

    /// 名前を確かめて一覧の最後に足す。
    @discardableResult
    public mutating func add(_ name: String) throws -> Entry {
        if let problem = BrowserProfile.problem(withName: name) { throw ProfileError("使えない名前: \(problem)") }
        guard entry(named: name) == nil else { throw ProfileError("「\(name)」はもうある") }
        let entry = Entry(name: name, dataStore: UUID())
        profiles.append(entry)
        return entry
    }
}

/// 実行ファイルを直に、呼んだ側とは別のセッションで起こす。環境変数は呼んだ側のものに `environment` を重ねて渡す。
///
/// `open` で頼むと前に出て、持ち主の作業を遮る。`open -g` で裏に起こすと SwiftUI が窓を作らない。
/// 直に起こせば窓は出て、前には出ない。別のセッションにするのは、呼んだ側が閉じても巻き添えで止まらないため。
public func spawnDetached(_ executable: String, environment: [String: String] = [:]) -> Bool {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // 呼んだ側の記述子は渡さない。操作用ソケットを引き継ぐと、呼んだ側が終わったあとも子がソケットを握ったままになり、
    // そこへ繋いだ browserctl が来ない応答を待ち続けた。
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    // 起こしたアプリを、呼んだ側ではなく自分自身の責任にする。そうしないと端末から起こした実体どうしで
    // WebKit の補助プロセスの持ち主が同じ端末になり、stats が別の実体のプロセスまで数えてしまう。
    // 関数は公開されていないので実行時に探し、なければそのまま起こす。
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
        let disclaim = unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self)
        _ = disclaim(&attributes, 1)
    }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    let merged = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let envp: [UnsafeMutablePointer<CChar>?] = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    return posix_spawn(&pid, executable, &actions, &attributes, argv, envp) == 0
}
