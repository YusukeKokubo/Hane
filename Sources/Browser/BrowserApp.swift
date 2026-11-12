import AppKit
import ControlWire
import SwiftUI

@main
struct BrowserApp: App {
    static let windowID = "main"

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
        WindowFrameMemory.install()
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
        Window("Browser", id: Self.windowID) {
            BrowserWindow(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1200, height: 800)
        // タブは閲覧状態（SessionStore）で戻すので、macOS の再開には任せない。任せると
        // ウインドウの状態が変わるたびに窓全体の画像を取って保存し、その写しで本体が25MBほど膨らんだまま戻らない。
        .restorationBehavior(.disabled)
        .commands {
            BrowserCommands(model: model)
        }

        Settings {
            SettingsView(settings: settings)
        }
    }
}

/// ウインドウの位置と大きさを覚えて、次の起動で戻す。
///
/// macOS の再開を切ったので、そのままでは毎回既定の大きさで開く。
/// SwiftUI には窓の位置を読み書きする手段がないため、ここだけ AppKit の自動保存を使う。
/// 開発用などの使い捨ての実体は別の名前で覚え、普段使いの窓の位置を動かさない。
@MainActor
enum WindowFrameMemory {
    static func install() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: \.canBecomeMain) else { return }
                _ = window.setFrameAutosaveName(name)
            }
        }
    }

    private static var name: String {
        BrowserInstance.name.map { "main-\($0)" } ?? "main"
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
