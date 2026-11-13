import Foundation

/// 環境変数 `HANE_INSTANCE` で選ぶ、アプリの実体（プロセス）の区別。
///
/// 実体を分けるのは、開発や計測で持ち主の普段使いに触れないためだけ。プロファイルは一つの実体の中で切り替える（`BrowserProfile`）。
/// 指定がなければ普段使いの実体で、持ち物を保存する。名前を付けた実体（dev、bench など）は何も保存しない使い捨てで、
/// 操作用ソケットも別になる。
public enum BrowserInstance {
    public static let environmentKey = "HANE_INSTANCE"
    public static let defaultName = "default"
    /// 以前の変数（名前を Hane にする前の実体の指定と、実体とプロファイルを兼ねていた頃のもの）。
    /// 付いたまま呼ばれると、黙って普段使いの実体を相手にしてしまうので断る。
    public static let retiredKeys = ["BROWSER_INSTANCE", "BROWSER_PROFILE", "BROWSER_EPHEMERAL"]

    /// 使い捨ての実体の名前。普段使いなら `nil`。
    public static let name: String? = {
        guard let value = ProcessInfo.processInfo.environment[environmentKey], !value.isEmpty, value != defaultName
        else { return nil }
        return value
    }()

    public static var isDefault: Bool { name == nil }
    public static var label: String { name ?? defaultName }

    /// この実体を動かしてはいけない理由。名前が使えないとき、普段使いへ落とすと持ち主のデータに触れてしまうので止める。
    public static var startupProblem: String? {
        let environment = ProcessInfo.processInfo.environment
        if let retired = retiredKeys.first(where: { environment[$0] != nil }) {
            return "\(retired) は使えなくなった。開発用の実体は \(environmentKey)=<名前> で分ける"
                + "（\(retired)=dev なら \(environmentKey)=dev）。プロファイルは実体の中で profile-open で切り替える。"
        }
        if let name, let problem = problem(withName: name) { return "\(environmentKey) の名前が使えない: \(problem)" }
        return nil
    }

    /// 持ち物の置き場。普段使いの実体だけが保存する。
    public static var dataDirectory: URL? { isDefault ? baseDirectory : nil }

    /// アプリの持ち物の根元。普段使いのプロファイル（`default`）の持ち物もここに直に置く。
    public static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hane", directoryHint: .isDirectory)
    }

    /// 操作用ソケットの置き場。普段使いは分ける前からの場所のまま。
    public static func socketPath(for name: String?) -> String {
        let directory = name.map { baseDirectory.appending(path: "instances/\($0)", directoryHint: .isDirectory) } ?? baseDirectory
        return directory.appending(path: "control.sock").path(percentEncoded: false)
    }

    /// 名前として使えないなら、その理由。名前はそのままパスに入るので、区切り文字や制御文字を除き、
    /// 操作用ソケットのパスが上限（104バイト）に収まる長さに限る。
    public static func problem(withName name: String) -> String? {
        if let problem = pathProblem(name) { return problem }
        if socketPath(for: name).utf8.count >= 104 { return "名前が長すぎる" }
        return nil
    }
}

/// 一つの実体の中で切り替えるプロファイル。Cookie などのサイトデータ、ブックマーク、閲覧履歴、閲覧状態を分けて持つ。
///
/// 普段使いの実体では `default` と、一覧（`ProfileRegistry`）に登録した名前。使い捨ての実体では `default` と、
/// その実体の中で作った名前で、どれも保存しない。
public enum BrowserProfile {
    public static let defaultName = "default"
    /// メニューや窓の題名に出すので、長すぎない名前に限る。
    public static let maxNameLength = 20

    /// プロファイルの置き場。`default` はプロファイルを分ける前からの場所（根元の直下）のままにして、持ち物を移さずに済ませる。
    public static func directory(for name: String, in base: URL = BrowserInstance.baseDirectory) -> URL {
        name == defaultName ? base : base.appending(path: "profiles/\(name)", directoryHint: .isDirectory)
    }

    /// 名前として使えないなら、その理由。名前はそのままパスに入る。
    public static func problem(withName name: String) -> String? {
        if name == defaultName { return "「\(defaultName)」は普段使いのプロファイルの名前" }
        if let problem = pathProblem(name) { return problem }
        if name.count > maxNameLength { return "名前が長すぎる（\(maxNameLength)文字まで）" }
        return nil
    }
}

/// パスの一部になる名前の決まり。
private func pathProblem(_ name: String) -> String? {
    if name.isEmpty { return "名前が空" }
    if name != name.trimmingCharacters(in: .whitespacesAndNewlines) { return "前後に空白がある" }
    if name.hasPrefix(".") { return "「.」で始まる名前は使えない" }
    if name.unicodeScalars.contains(where: { $0 == "/" || $0 == ":" || CharacterSet.controlCharacters.contains($0) }) {
        return "「/」「:」や改行は使えない"
    }
    return nil
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
    /// 最後に開いていたプロファイル。次の起動でそれを開く。ないときや一覧にないときは `default`。
    /// 後から足した項目なので、前の版のファイルにはない（Optional なので、なくても読める）。
    public var lastOpened: String?
    /// 終えたときに窓を開いていたプロファイル（`lastOpened` も含む、窓を開いた順）。次の起動でそれぞれの窓を戻す。
    /// `lastOpened` と同じく後から足した項目で、ないときは `lastOpened` の窓だけを開く。
    public var lastWindows: [String]?

    public init() {}

    public static var fileURL: URL { fileURL(in: BrowserInstance.baseDirectory) }

    public static func fileURL(in base: URL) -> URL {
        base.appending(path: "profiles.json")
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
    // そこへ繋いだ hanectl が来ない応答を待ち続けた。
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
