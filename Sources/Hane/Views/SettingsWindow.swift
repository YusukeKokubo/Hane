import AppKit
import SwiftUI

/// 設定の窓（⌘,）。一枚だけ持ち、開いていれば前に出す。
///
/// メニューを AppKit で組むので、SwiftUI の `Settings` シーンに頼らず窓も AppKit で作る。
/// 閉じたら中身ごと手放し、開いていない間に画面を抱えない。
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private var window: NSWindow?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(settings: settings))
        // 中身の大きさに窓を合わせる。
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "設定"
        // 設定の窓は起動時に戻さない。
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
    }
}
