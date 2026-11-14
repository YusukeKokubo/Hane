import AppKit
import ControlWire

/// アプリの起動の段取りと、起動したあとに AppKit から受ける知らせ。入口（main.swift）が作って `NSApp` に付ける。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: BrowserModel
    private let mainMenu: MainMenu
    private let control: ControlService

    override init() {
        if let problem = BrowserInstance.startupProblem {
            FileHandle.standardError.write(Data((problem + "\n").utf8))
            AppLog.logger.error("起動をやめました: \(problem, privacy: .public)")
            exit(1)
        }
        RunningInstance.handOffIfAlreadyRunning()
        // システムの設定で窓が一つの窓のタブにまとまったり、メニューに「タブバーを表示」が足されたりしないように。
        // タブはアプリが自分で持つ。
        NSWindow.allowsAutomaticWindowTabbing = false
        // ページを作る前に、共有の環境設定へ値を入れておく。
        let settings = SettingsStore.forInstance()
        let blocker = ContentBlocker.forInstance()
        Task { await blocker.prepare() }
        let model = BrowserModel.forInstance(contentBlocker: blocker)
        model.makeWindow = { [weak model] slot in
            guard let model else { return }
            MainWindow.open(slot, model: model)
        }
        self.model = model
        mainMenu = MainMenu(model: model, settings: settings)
        control = ControlService(model: model, settings: settings)
        super.init()
        let app = NSApplication.shared
        app.mainMenu = mainMenu.menu
        app.servicesMenu = mainMenu.servicesMenu
        app.windowsMenu = mainMenu.windowsMenu
        app.helpMenu = mainMenu.helpMenu
        control.start()
        ExternalLinks.install(model: model)
        InstanceMark.install()
        // 閲覧状態と履歴は変化から少し遅れて書き出すので、
        // 終了直前の変化を取りこぼさないよう最後にもう一度書く。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { model.saveBeforeQuit() }
        }
    }

    /// 起動したときに覚えていた窓を開く。
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.restoreWindows()
    }

    /// Dock からの開き直しで、窓がなければ窓を出す。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard model.windows.isEmpty else { return true }
        model.reopen()
        return false
    }
}

/// 使い捨ての実体に、Dock のアイコンで見分けがつく印を付ける。普段使いの実体と同じアイコンが並ぶため。
@MainActor
enum InstanceMark {
    static func install() {
        guard let name = BrowserInstance.name else { return }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp.dockTile.badgeLabel = name
            }
        }
    }
}
