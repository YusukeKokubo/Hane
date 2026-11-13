import AppKit
import ControlWire
import SwiftUI

@main
struct HaneApp: App {
    static let windowID = "main"
    /// ⌘N や、起動したときに戻す二枚目からの窓。
    static let moreWindowsID = "more"

    @State private var model: BrowserModel
    @State private var settings: SettingsStore
    private let control: ControlService

    init() {
        if let problem = BrowserInstance.startupProblem {
            FileHandle.standardError.write(Data((problem + "\n").utf8))
            NSLog("起動をやめました: \(problem)")
            exit(1)
        }
        RunningInstance.handOffIfAlreadyRunning()
        // ページを作る前に、共有の環境設定へ値を入れておく。
        let settings = SettingsStore.forInstance()
        let blocker = ContentBlocker.forInstance()
        Task { await blocker.prepare() }
        let model = BrowserModel.forInstance(contentBlocker: blocker)
        _model = State(initialValue: model)
        _settings = State(initialValue: settings)
        control = ControlService(model: model, settings: settings)
        control.start()
        LocalShortcuts.install(model: model)
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
        // 窓一枚にプロファイルを一つずつ出す。どの窓にどれを出すかは BrowserModel が決める。
        // 最初の窓は Window にする。WindowGroup は、hanectl のように裏で直に起こすと起動したときの窓を作らないため。
        Window("Hane", id: Self.windowID) {
            BrowserWindow(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        // タブは閲覧状態（SessionStore）で戻すので、macOS の再開には任せない。任せると
        // ウインドウの状態が変わるたびに窓全体の画像を取って保存し、その写しで本体が25MBほど膨らんだまま戻らない。
        .restorationBehavior(.disabled)
        .commands {
            BrowserCommands(model: model)
        }

        WindowGroup("Hane", id: Self.moreWindowsID) {
            BrowserWindow(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(settings: settings)
        }
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
        // 窓の中でプロファイルを切り替えたときは窓を動かさず、今の位置をそのプロファイルのものとして覚える。
        if !window.frameAutosaveName.isEmpty {
            window.saveFrame(usingName: name)
        }
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
