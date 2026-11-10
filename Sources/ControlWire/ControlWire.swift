import Foundation

/// コマンドからアプリへ送る要求。コマンドライン引数をそのまま運ぶ。
public struct ControlRequest: Codable, Sendable {
    public var args: [String]

    public init(args: [String]) {
        self.args = args
    }
}

/// アプリからコマンドへ返す結果。`output` は人にもLLMにも読める文字列。
public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var output: String

    public init(ok: Bool, output: String) {
        self.ok = ok
        self.output = output
    }
}

/// 環境変数 `BROWSER_PROFILE` で選ぶ、アプリの実体の区別。
///
/// 指定がなければ普段使いの `default`。それ以外の名前では、操作用ソケットが別になり、
/// Cookieなどのサイトデータも保存されない使い捨てになる。
public enum BrowserProfile {
    public static let environmentKey = "BROWSER_PROFILE"
    public static let defaultName = "default"

    public static let name: String = {
        guard let value = ProcessInfo.processInfo.environment[environmentKey], !value.isEmpty,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return defaultName }
        return value
    }()

    public static var isDefault: Bool { name == defaultName }
}

public struct ControlSocketError: Error, CustomStringConvertible {
    public let description: String
}

/// Unixドメインソケットの薄い包み。1接続につき、改行で終わるJSONを1往復だけやり取りする。
public enum ControlSocket {
    public static let bundleIdentifier = "local.personal.browser"

    /// 待ち受け場所。利用者のライブラリ配下なので、他のユーザーからは届かない。
    /// プロファイルごとに別の場所になるので、開発用の実体と普段使いの実体は混ざらない。
    public static var path: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let relative = BrowserProfile.isDefault
            ? "Browser/control.sock"
            : "Browser/profiles/\(BrowserProfile.name)/control.sock"
        return base.appending(path: relative).path(percentEncoded: false)
    }

    /// 待ち受け用のソケットを作って返す。前回の残骸があれば置き換える。
    public static func listen(at path: String) throws -> Int32 {
        let directory = URL(filePath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("socket") }
        var address = try address(for: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let error = failure("bind/listen")
            close(fd)
            throw error
        }
        return fd
    }

    /// 接続できなければ `nil`（アプリが起動していない場合など）。
    public static func connect(to path: String) -> Int32? {
        guard var address = try? address(for: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// 相手が先に切っても、書き込みでプロセスごと落ちないようにする。
    public static func ignoreBrokenPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 改行（または切断）までを1通として読む。
    public static func readMessage(from fd: Int32) -> Data? {
        var message = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                message.append(contentsOf: buffer[..<newline])
                return message
            }
            message.append(contentsOf: buffer[..<count])
        }
        return message.isEmpty ? nil : message
    }

    /// 1通を書き、終わりの改行を付ける。
    public static func writeMessage(_ message: Data, to fd: Int32) {
        var bytes = [UInt8](message)
        bytes.append(0x0A)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            offset += count
        }
    }

    private static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlSocketError(description: "ソケットのパスが長すぎます: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func failure(_ operation: String) -> ControlSocketError {
        ControlSocketError(description: "\(operation) に失敗: \(String(cString: strerror(errno)))")
    }
}
