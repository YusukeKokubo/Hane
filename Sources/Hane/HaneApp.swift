import AppKit
import ControlWire
import SwiftUI

@main
struct HaneApp: App {
    /// 本体の窓の識別子。窓まわりの部品を拾うときに、設定の窓と見分ける。
    static let windowID = "main"

    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: BrowserModel
    @State private var settings: SettingsStore
    private let control: ControlService

    init() {
        if let problem = BrowserInstance.startupProblem {
            FileHandle.standardError.write(Data((problem + "\n").utf8))
            AppLog.logger.error("起動をやめました: \(problem, privacy: .public)")
            exit(1)
        }
        RunningInstance.handOffIfAlreadyRunning()
        // ページを作る前に、共有の環境設定へ値を入れておく。
        let settings = SettingsStore.forInstance()
        let blocker = ContentBlocker.forInstance()
        Task { await blocker.prepare() }
        let model = BrowserModel.forInstance(contentBlocker: blocker)
        model.makeWindow = { [weak model] slot in
            guard let model else { return }
            MainWindow.open(slot, model: model)
        }
        AppDelegate.model = model
        _model = State(initialValue: model)
        _settings = State(initialValue: settings)
        control = ControlService(model: model, settings: settings)
        control.start()
        LocalShortcuts.install(model: model)
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

    var body: some Scene {
        // 本体の窓は AppKit で作る（MainWindow）。モデルの側からその場で開けるようにするため。
        // シーンは設定の窓だけで、メニューはここに付ける。
        Settings {
            SettingsView(settings: settings)
        }
        .commands {
            BrowserCommands(model: model, settings: settings)
        }
    }
}

/// 起動したときに覚えていた窓を開き、Dock からの開き直しで窓を出す。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: BrowserModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.model?.restoreWindows()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let model = Self.model, model.windows.isEmpty else { return true }
        model.reopen()
        return false
    }
}

/// ウインドウの位置と大きさを、プロファイルごとに覚えて次に開いたときに戻す。
///
/// macOS の再開を切ったので、そのままでは毎回既定の大きさで開く。
/// SwiftUI には窓の位置を読み書きする手段がないため、ここだけ AppKit の自動保存を使う。
/// 開発用などの使い捨ての実体は別の名前で覚え、普段使いの窓の位置を動かさない。
@MainActor
enum WindowFrameMemory {
    /// 窓にプロファイルを出したときに呼ぶ。覚えていた位置があれば、そこへ動かす。
    static func remember(_ window: NSWindow, as profile: String) {
        let name = name(for: profile)
        guard window.frameAutosaveName != name else { return }
        _ = window.setFrameAutosaveName(name)
    }

    /// 標準のプロファイルは、窓を一枚しか開けなかった頃の名前のまま。
    static func name(for profile: String) -> String {
        let base = BrowserInstance.name.map { "main-\($0)" } ?? "main"
        return profile == BrowserProfile.defaultName ? base : "\(base)-profile-\(profile)"
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
