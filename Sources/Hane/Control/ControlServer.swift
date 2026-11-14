import ControlWire
import Foundation

/// 操作用ソケットで待ち受け、届いた要求を1件ずつ `handler` に渡す。
///
/// アプリが動いている間、`stop()` されるまで待ち受ける。ソケットの残骸は次回起動時に置き換える。
enum ControlServer {
    typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    /// 待ち受けているソケット。止めると、そのパスへの接続は届かなくなる。
    final class Listener: Sendable {
        let fd: Int32
        let path: String

        fileprivate init(fd: Int32, path: String) {
            self.fd = fd
            self.path = path
        }

        /// パスを消して待ち受けをやめる。一度だけ呼ぶ（二度閉じると、使い回された別の記述子を閉じてしまう）。
        ///
        /// 先にパスを消すので、次の `hanectl` はつながらず、実体がいないとみなして新しい実体を起こす。
        /// 待ち受けの糸は、閉じると `accept` が失敗して終わる。受け付け済みの要求には、そのまま答える。
        func stop() {
            unlink(path)
            close(fd)
        }
    }

    static func start(path: String = ControlSocket.path, handler: @escaping Handler) throws -> Listener {
        let listener = try ControlSocket.listen(at: path)
        let queue = DispatchQueue(label: "control.io", qos: .userInitiated, attributes: .concurrent)

        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                ControlSocket.ignoreBrokenPipe(client)
                queue.async {
                    serve(client, on: queue, handler: handler)
                }
            }
        }
        return Listener(fd: listener, path: path)
    }

    private static func serve(_ client: Int32, on queue: DispatchQueue, handler: @escaping Handler) {
        guard let data = ControlSocket.readMessage(from: client) else {
            close(client)
            return
        }
        Task {
            let response: ControlResponse
            if let request = try? JSONDecoder().decode(ControlRequest.self, from: data) {
                response = await handler(request)
            } else {
                response = ControlResponse(ok: false, output: "要求を読み取れませんでした")
            }
            let encoded = (try? JSONEncoder().encode(response)) ?? Data()
            // ソケットへの書き込みは詰まりうるので、協調スレッドの外で行う。
            queue.async {
                ControlSocket.writeMessage(encoded, to: client)
                close(client)
            }
        }
    }
}
