import WebKit

/// すべてのページに、WebKit のプロセスの束ね役（プロセスプール）と環境設定（`WKPreferences`）を一つずつ共有させる。
///
/// 設定を別々に作るとプールも別々になり、別のサイトへ移ったときに「戻る」用に残すページ（プールごとに2つ）と、
/// 次に備えて先に立ち上げる予備のプロセス（プールごとに1つ）がタブの数だけ溜まる（6枚で別のサイトへ一度ずつ移ると、
/// 共有しないと18個、共有すると8個だった）。写した設定はプールと環境設定を元と同じものに保つので、
/// ここにある元の設定をプロファイルごとに写して使う。
///
/// 環境設定を一つにしておけば、設定画面で変えた値（ポップアップを止めるかなど）が開いているタブにもその場で効く。
@MainActor
enum SharedConfiguration {
    /// 全ページの環境設定。値は `SettingsStore` が入れる。既定ではポップアップを止める。
    static var preferences: WKPreferences { root.preferences }

    /// プロファイルごとの設定の元。写すとプールと環境設定は共有されたまま、サイトデータの置き場などを変えられる。
    static func copy() -> WKWebViewConfiguration {
        root.copy() as! WKWebViewConfiguration
    }

    private static let root: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // プールは初めて読まれたときに作られる。写す前に元で作っておかないと、写した先でめいめいが別のプールを作り、
        // プロファイルの窓が増えるごとにページのプロセスが3つずつ余計に溜まる（macOS 27 で確かめた）。
        // 読み口（processPool）は非推奨で警告になるので、名前で読む。
        _ = configuration.value(forKey: "processPool")
        return configuration
    }()
}
