import Foundation
import ObjectiveC
import WebKit

/// すべてのタブに、WebKit のプロセスの束ね役（プロセスプール）と環境設定（`WKPreferences`）を一つずつ共有させる。
///
/// `WebPage` はページごとに新しいプールを作り、公開の設定にはプールを渡す口がない。プールが別々だと、
/// 別のサイトへ移ったときに「戻る」用に残すページ（プールごとに2つ）と、次に備えて先に立ち上げる予備のプロセス
/// （プールごとに1つ）がタブの数だけ溜まる。タブ3枚で別のサイトへ一度ずつ移ると、ページのプロセスは
/// 共有しないと10個、共有すると6個だった（1個あたり 7〜14MB）。
///
/// 環境設定も公開の設定から渡す口がない。一つを共有しておけば、設定画面で変えた値（ポップアップを止めるかなど）が
/// 開いているタブにもその場で効く。
///
/// `WebPage` は Web ビューを作るとき内部で `WKWebViewConfiguration` を作るので、その `init` を差し替えて
/// 共有のものを入れる。範囲を `WKWebViewConfiguration` 自身の `init` に限り、見つからなければ何もしない
/// （WebKit が変わってもページは開ける。外れたことは `InternalsCheck` が起動した後の最初のページで確かめて知らせる）。
@MainActor
enum SharedConfiguration {
    /// 全タブの環境設定。値は `SettingsStore` が入れる。既定ではポップアップを止める。
    static let preferences: WKPreferences = {
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = false
        return preferences
    }()

    /// 一度だけ差し替える。`PageFactory` がページを作る前に呼ぶ。
    static func install() { _ = pool }

    /// Web ビューが共有のプールと環境設定を使っているかを確かめ、外れている所を利用者向けの文で返す。
    /// 差し替えは外れてもページは開くので、`InternalsCheck` が最初のページでこれを呼んで知らせる。
    static func problems(in webView: WKWebView) -> [String] {
        // configuration は写しを返すが、写しはプールと環境設定を元の Web ビューのものにそろえて返す
        // （`pagesShareOneProcessPool` と `internalsCheckSeesWhatTheWebViewUses` のテストで見ている）。
        let configuration = webView.configuration
        let reason = pool == nil ? "（WKWebViewConfiguration の init を差し替えられませんでした）" : ""
        var problems: [String] = []
        let current = configuration.responds(to: NSSelectorFromString("processPool"))
            ? configuration.value(forKey: "processPool") as AnyObject? : nil
        if pool == nil || current !== pool {
            problems.append("プロセスプールを共有できていません\(reason)。タブを増やすとページのプロセスが溜まります")
        }
        if configuration.preferences !== preferences {
            problems.append("環境設定を共有できていません\(reason)。設定で変えたポップアップの可否が、開いているタブに効きません")
        }
        return problems
    }

    /// 全タブで共有するプール。差し替えられなかったときは `nil`。
    private static let pool: NSObject? = {
        let configuration: AnyClass = WKWebViewConfiguration.self
        let selector = #selector(NSObject.init)
        // 親（NSObject）の init を差し替えると、すべてのオブジェクトの生成が変わってしまう。
        // WKWebViewConfiguration 自身が init を持っているときだけ差し替える。
        guard let method = class_getInstanceMethod(configuration, selector),
              let inherited = class_getInstanceMethod(NSObject.self, selector),
              method_getImplementation(method) != method_getImplementation(inherited),
              // 名前で入れるので、受け口がなくなっていたら落ちずに諦める。
              WKWebViewConfiguration.instancesRespond(to: NSSelectorFromString("setProcessPool:"))
        else { return nil }
        // WKProcessPool は「複数作っても意味がない」として非推奨だが、WebPage の下では実際にページごとに分かれる。
        // 型の名前で作り、非推奨の警告を出さないようにする。
        guard let poolType = NSClassFromString("WKProcessPool") as? NSObject.Type else { return nil }
        let pool = poolType.init()
        let preferences = Self.preferences

        typealias Initializer = @convention(c) (AnyObject, Selector) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let replacement: @convention(block) (AnyObject) -> AnyObject? = { object in
            let made = original(object, selector)
            // setProcessPool: は非推奨の公開APIなので、警告を出さないよう名前で呼ぶ。
            (made as? NSObject)?.setValue(pool, forKey: "processPool")
            (made as? WKWebViewConfiguration)?.preferences = preferences
            return made
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return pool
    }()
}
