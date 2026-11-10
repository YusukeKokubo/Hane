import ControlWire
import Foundation

/// 操作用ソケットで待ち受け、届いた要求を1件ずつ `handler` に渡す。
///
/// アプリが動いている間ずっと待ち受ける。ソケットの残骸は次回起動時に置き換える。
enum ControlServer {
    typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    static func start(path: String = ControlSocket.path, handler: @escaping Handler) throws {
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
