import SwiftUI

@main
struct BrowserApp: App {
    static let windowID = "main"

    @State private var store = TabStore()

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
