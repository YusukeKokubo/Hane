import AppKit
import ControlWire
import SwiftUI

@main
struct BrowserApp: App {
    static let windowID = "main"

    @State private var store: TabStore
    private let control: ControlService

    init() {
        let blocker = ContentBlocker.forCurrentProfile()
        Task { await blocker.prepare() }
        let store = TabStore(
            factory: PageFactory(contentBlocker: blocker),
            bookmarks: .forCurrentProfile(),
            history: .forCurrentProfile(),
            session: .forCurrentProfile()
        )
        _store = State(initialValue: store)
        control = ControlService(store: store)
        control.start()
        FolderShortcut.install(store: store)
        WindowFrameMemory.install()
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
            BrowserWindow(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1200, height: 800)
        // タブは閲覧状態（SessionStore）で戻すので、macOS の再開には任せない。任せると
        // ウインドウの状態が変わるたびに窓全体の画像を取って保存し、その写しで本体が25MBほど膨らんだまま戻らない。
        .restorationBehavior(.disabled)
        .commands {
            BrowserCommands(store: store)
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
                _ = NSApp.windows.first { $0.canBecomeMain }?.setFrameAutosaveName(name)
            }
        }
    }

    private static var name: String {
        BrowserProfile.isDefault ? "main" : "main-\(BrowserProfile.name)"
    }
}
