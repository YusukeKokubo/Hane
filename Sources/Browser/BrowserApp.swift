import SwiftUI

@main
struct BrowserApp: App {
    static let windowID = "main"

    @State private var store: TabStore
    private let control: ControlService

    init() {
        let store = TabStore(bookmarks: .forCurrentProfile())
        _store = State(initialValue: store)
        control = ControlService(store: store)
        control.start()
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
