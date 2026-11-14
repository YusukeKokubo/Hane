import Foundation
import WebKit

/// スクリプトが渡した子フレームの窓（`window.webkit.createJSHandle(iframe.contentWindow)`）から、
/// そのフレームを WebKit に引き直させる口。macOS 27 の WebKit で公開された API（`WKContentWorldConfiguration` の
/// `jsHandleCreationEnabled` と `WKJSHandle` の `windowProxyFrame`）を使う。
///
/// ビルドに使っている SDK（Xcode 26.5）の定義にはまだ載っていないので、公開されている名前で呼んでいる。
/// SDK が 27 になったら `WKContentWorld(configuration:)` と `await handle.windowProxyFrame` を直に使う形に戻す。
/// 動いている WebKit が古くて口がなければ、子フレームは引けないものとして扱う。
@MainActor
enum FrameHandles {
    /// `createJSHandle` を使える実行環境。WebKit に口がなければ nil。
    /// 設定から作った実行環境は名前で引き直せないので、受け取った側が持ち続けること。
    static func makeWorld() -> WKContentWorld? {
        guard let type = NSClassFromString("WKContentWorldConfiguration") as? NSObject.Type else { return nil }
        let configuration = type.init()
        let enable = NSSelectorFromString("setJSHandleCreationEnabled:")
        let create = NSSelectorFromString("worldWithConfiguration:")
        guard configuration.responds(to: enable), WKContentWorld.responds(to: create) else { return nil }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(configuration.method(for: enable), to: Setter.self)(configuration, enable, true)
        return WKContentWorld.perform(create, with: configuration)?.takeUnretainedValue() as? WKContentWorld
    }

    /// スクリプトが返した値が子フレームの窓なら、そのフレーム。違えば nil。
    static func frame(of handle: Any?) async -> WKFrameInfo? {
        let selector = NSSelectorFromString("getWindowProxyFrameWithCompletionHandler:")
        guard let object = handle as? NSObject, object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, @escaping @convention(block) (WKFrameInfo?) -> Void) -> Void
        let get = unsafeBitCast(object.method(for: selector), to: Getter.self)
        let box = await withCheckedContinuation { (continuation: CheckedContinuation<FrameBox, Never>) in
            get(object, selector) { frame in continuation.resume(returning: FrameBox(frame: frame)) }
        }
        return box.frame
    }

    /// WebKit は答えをメインスレッドで返すが、型の上ではそれを言えないので包んで渡す。
    private struct FrameBox: @unchecked Sendable {
        let frame: WKFrameInfo?
    }
}
