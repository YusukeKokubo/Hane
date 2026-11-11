import Foundation
import ObjectiveC
import WebKit

/// すべてのタブに、WebKit のプロセスの束ね役（プロセスプール）を一つだけ共有させる。
///
/// `WebPage` はページごとに新しいプールを作り、公開の設定にはプールを渡す口がない。プールが別々だと、
/// 別のサイトへ移ったときに「戻る」用に残すページ（プールごとに2つ）と、次に備えて先に立ち上げる予備のプロセス
/// （プールごとに1つ）がタブの数だけ溜まる。タブ3枚で別のサイトへ一度ずつ移ると、ページのプロセスは
/// 共有しないと10個、共有すると6個だった（1個あたり 7〜14MB）。
///
/// `WebPage` は Web ビューを作るとき内部で `WKWebViewConfiguration` を作るので、その `init` を差し替えて
/// 共有のプールを入れる。範囲を `WKWebViewConfiguration` 自身の `init` に限り、見つからなければ何もしない
/// （WebKit が変わってもページは開ける。`pagesShareOneProcessPool` のテストが知らせる）。
@MainActor
enum SharedProcessPool {
    /// 一度だけ差し替える。`PageFactory` がページを作る前に呼ぶ。
    static func install() { _ = installed }

    private static let installed: Bool = {
        let configuration: AnyClass = WKWebViewConfiguration.self
        let selector = #selector(NSObject.init)
        // 親（NSObject）の init を差し替えると、すべてのオブジェクトの生成が変わってしまう。
        // WKWebViewConfiguration 自身が init を持っているときだけ差し替える。
        guard let method = class_getInstanceMethod(configuration, selector),
              let inherited = class_getInstanceMethod(NSObject.self, selector),
              method_getImplementation(method) != method_getImplementation(inherited)
        else { return false }
        // WKProcessPool は「複数作っても意味がない」として非推奨だが、WebPage の下では実際にページごとに分かれる。
        // 型の名前で作り、非推奨の警告を出さないようにする。
        guard let poolType = NSClassFromString("WKProcessPool") as? NSObject.Type else { return false }
        let pool = poolType.init()

        typealias Initializer = @convention(c) (AnyObject, Selector) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let replacement: @convention(block) (AnyObject) -> AnyObject? = { object in
            let made = original(object, selector)
            // setProcessPool: は非推奨の公開APIなので、警告を出さないよう名前で呼ぶ。
            (made as? NSObject)?.setValue(pool, forKey: "processPool")
            return made
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return true
    }()
}
