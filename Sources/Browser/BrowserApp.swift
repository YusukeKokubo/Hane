import AppKit
import ControlWire
import SwiftUI

@main
struct BrowserApp: App {
    static let windowID = "main"

    @State private var store: TabStore
    @State private var profiles: ProfileSwitcher
    @State private var settings: SettingsStore
    private let control: ControlService

    init() {
        ProfileSwitcher.handOffIfAlreadyRunning()
        // ページを作る前に、共有の環境設定へ値を入れておく。
        let settings = SettingsStore.forCurrentProfile()
        let blocker = ContentBlocker.forCurrentProfile()
        Task { await blocker.prepare() }
        let store = TabStore(
            factory: PageFactory(contentBlocker: blocker),
            bookmarks: .forCurrentProfile(),
            history: .forCurrentProfile(),
            session: .forCurrentProfile()
        )
        let profiles = ProfileSwitcher.forCurrentProfile()
        _store = State(initialValue: store)
        _profiles = State(initialValue: profiles)
        _settings = State(initialValue: settings)
        control = ControlService(store: store, profiles: profiles, settings: settings)
        control.start()
        LocalShortcuts.install(store: store, profiles: profiles)
        WindowFrameMemory.install()
        ProfileMark.install()
        // 別の実体で足したプロファイルをメニューに出すため、前に出るたびに一覧を読み直す（小さなファイル一つ）。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { profiles.reload() }
        }
        // 閲覧状態と履歴は変化から少し遅れて書き出すので、
        // 終了直前の変化を取りこぼさないよう最後にもう一度書く。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                store.saveSession()
                store.history.saveNow()
            }
        }
    }

    var body: some Scene {
        Window("Browser", id: Self.windowID) {
            BrowserWindow(store: store, profiles: profiles)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1200, height: 800)
        // タブは閲覧状態（SessionStore）で戻すので、macOS の再開には任せない。任せると
        // ウインドウの状態が変わるたびに窓全体の画像を取って保存し、その写しで本体が25MBほど膨らんだまま戻らない。
        .restorationBehavior(.disabled)
        .commands {
            BrowserCommands(store: store, profiles: profiles)
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
/// 開発用などのプロファイルは別の名前で覚え、普段使いの窓の位置を動かさない。
@MainActor
enum WindowFrameMemory {
    static func install() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: \.canBecomeMain) else { return }
                _ = window.setFrameAutosaveName(name)
                // 別のプロファイルから切り替えて起こされたときは、覚えた枠より、元の窓の枠に重ねる方を選ぶ。
                if let frame = ProcessInfo.processInfo.environment[handOverKey] { take(frame, into: window) }
            }
        }
    }

    /// 切り替え先の実体を起こすとき、元の窓の枠を渡す環境変数。
    static let handOverKey = "BROWSER_WINDOW_FRAME"

    /// 切り替え先の実体へ渡す、今の窓の枠（AppKit の画面全体の座標で `x,y,幅,高さ`）。
    ///
    /// プロファイルの実体は別々なので、切り替え先の窓を同じところに重ねて元の実体を隠し、
    /// 一つの窓の中身が入れ替わったように見せる。全画面や最小化のときは重ねようがないので空にする
    /// （空でも渡すのは、元の実体が起こされたときに受け取った古い値を、起こす先へ引き継がないため）。
    static func handOver() -> String {
        guard let window = mainWindow, !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return "" }
        let frame = window.frame
        return [frame.minX, frame.minY, frame.width, frame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
    }

    /// 渡された枠に窓を合わせる。読めない値や、どの画面にもかからない枠（外した画面を指すものなど）は無視する。
    @discardableResult
    static func take(_ text: String, into window: NSWindow? = mainWindow) -> Bool {
        let values = text.split(separator: ",").compactMap { Double($0) }
        guard values.count == 4, values[2] >= 200, values[3] >= 200 else { return false }
        let frame = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
        guard let window, !window.styleMask.contains(.fullScreen),
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return false }
        window.setFrame(frame, display: true)
        return true
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == BrowserApp.windowID }
    }

    private static var name: String {
        BrowserProfile.isDefault ? "main" : "main-\(BrowserProfile.name)"
    }
}

/// 普段使い以外のプロファイルの実体に、Dock のアイコンで見分けがつく印を付ける。
///
/// プロファイルごとに実体が分かれるので、Dock と ⌘Tab には同じアイコンが並ぶ。
@MainActor
enum ProfileMark {
    static func install() {
        guard !BrowserProfile.isDefault else { return }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp.dockTile.badgeLabel = BrowserProfile.name
            }
        }
    }
}
