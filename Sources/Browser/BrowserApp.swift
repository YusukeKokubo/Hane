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
            session: .forCurrentProfile()
        )
        _store = State(initialValue: store)
        control = ControlService(store: store)
        control.start()
        FolderShortcut.install(store: store)
        // 変化のたびに書き出してはいるが、その書き出しは処理の回の終わりまで待つので、
        // 終了直前の変化を取りこぼさないよう最後にもう一度書く。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { store.saveSession() }
        }
    }

    var body: some Scene {
        Window("Browser", id: Self.windowID) {
            BrowserWindow(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1200, height: 800)
        .commands {
            BrowserCommands(store: store)
        }
    }
}
