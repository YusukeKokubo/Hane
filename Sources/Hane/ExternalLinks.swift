import AppKit
import ControlWire

/// 外から渡されたリンク（既定のブラウザとして、ほかのアプリで踏まれたもの）を開く。
///
/// メニューや外部操作と同じく、最後に前へ出たプロファイルの窓（`BrowserModel.store`）に新しいタブで開く。
@MainActor
enum ExternalLinks {
    private static var receiver: Receiver?

    static func install(model: BrowserModel) {
        receiver = Receiver(model: model)
        // AppKit は起動の途中で自分の受け口を置くので、それより後の willFinishLaunching で差し替える。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSAppleEventManager.shared().setEventHandler(
                    ExternalLinks.receiver as Any, andSelector: #selector(Receiver.handle(_:reply:)),
                    forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
            }
        }
    }

    /// 開くリンクか。既定のブラウザとして受け持つのは http と https だけ。
    static func url(from string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    static func open(_ url: URL, in model: BrowserModel) {
        if place(url, in: model) {
            bringToFront(model)
            return
        }
        // 窓をすべて閉じている。最後に前へ出ていたプロファイルの窓を開いて置く。
        model.openLastProfile()
        guard place(url, in: model) else {
            AppLog.logger.error("外から渡されたリンクを開けませんでした（窓が開かなかった）: \(url.absoluteString, privacy: .public)")
            return
        }
        bringToFront(model)
    }

    /// 今のプロファイルのタブ管理にリンクを置く。窓を前に出すのは `open` の役目。
    /// プロファイルを出している窓がひとつもなければ、置かずに `false` を返す。
    @discardableResult
    static func place(_ url: URL, in model: BrowserModel) -> Bool {
        // プロファイルを選ぶ前の窓しか残っていなければ、そこへ最後に前へ出ていたプロファイルを出す。
        if model.store == nil, model.windows.contains(where: { $0.profile == nil }) {
            model.openLastProfile()
        }
        guard let store = model.store else { return false }
        let request = URLRequest(url: url)
        // 開いたばかりの空のタブが選ばれていれば、そこで開く。並べると使わない空のタブが残る。
        if let tab = store.selected, case .empty = tab.content {
            tab.load(request, from: .external)
        } else {
            store.open(request, from: .external)
        }
        return true
    }

    /// 今のプロファイルの窓を前に出す。
    static func bringToFront(_ model: BrowserModel) {
        NSApp.unhide(nil)
        if let window = model.currentWindow ?? NSApp.windows.first(where: \.canBecomeMain) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    @MainActor
    private final class Receiver: NSObject {
        let model: BrowserModel

        init(model: BrowserModel) {
            self.model = model
        }

        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
                  let url = ExternalLinks.url(from: string)
            else { return }
            // 開発用の実体も同じバンドルIDなので、動いているとリンクが届くことがある。
            // 使い捨ての窓に開くと閉じたときに失うので、受けずに知らせるだけにする。
            guard BrowserInstance.isDefault else {
                AppLog.logger.notice("外から渡されたリンクを開きませんでした（開発用の実体のため）: \(url.absoluteString, privacy: .public)")
                return
            }
            ExternalLinks.open(url, in: model)
        }
    }
}

/// 既定のブラウザかどうかと、既定にする頼み。設定の窓から使う。
@MainActor
enum DefaultBrowser {
    private static let schemes = ["http", "https"]

    /// 既定にできる実体か。受け持つと宣言しているのは置いた方だけで、開発用の build/Hane.app は宣言を外してある（`bundle.sh`）。
    static var canBecomeDefault: Bool { BrowserInstance.isDefault }

    /// Hane が http と https の両方を受け持っているか。同じバンドルIDの別の場所のものでも Hane と見る。
    static var isDefault: Bool {
        schemes.allSatisfy(handles)
    }

    /// 既定にする。macOS が確かめる窓を出し、持ち主が選ぶまで待つ。
    static func becomeDefault() async throws {
        // 済んでいるものまで頼むと、確かめる窓が余計に出る。
        for scheme in schemes where !handles(scheme) {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
        }
    }

    private static func handles(_ scheme: String) -> Bool {
        guard let url = URL(string: "\(scheme)://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
