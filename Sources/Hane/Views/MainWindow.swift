import AppKit
import ControlWire
import SwiftUI

/// 本体の窓一枚の持ち主。AppKit の窓を作って中身に `BrowserWindow` を載せ、前に出た・閉じたを `BrowserModel` へ伝える。
///
/// SwiftUI のシーンで窓を開く `openWindow` は画面の中からしか呼べず、モデルの側から窓を開くのに回り道が要ったため、
/// 窓は AppKit で作る。
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    /// 本体の窓の識別子。窓まわりの部品を拾うときに、設定の窓と見分ける。
    static let windowID = "main"

    /// 開いている窓の持ち主。窓が閉じるまで掴んでおく。
    private static var owners: [MainWindow] = []

    let window: NSWindow
    let slot: BrowserWindowSlot
    private let model: BrowserModel

    /// `BrowserModel.makeWindow` に渡す。
    static func open(_ slot: BrowserWindowSlot, model: BrowserModel) {
        let owner = MainWindow(slot: slot, model: model)
        owners.append(owner)
        owner.window.makeKeyAndOrderFront(nil)
    }

    private init(slot: BrowserWindowSlot, model: BrowserModel) {
        self.slot = slot
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        // タブバーをタイトルバーの位置に置く。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // タブは閲覧状態（SessionStore）で戻すので、macOS の再開には任せない。任せると
        // ウインドウの状態が変わるたびに窓全体の画像を取って保存し、その写しで本体が25MBほど膨らんだまま戻らない。
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
        let hosting = NSHostingController(rootView: BrowserWindow(model: model, slot: slot))
        // 大きさは窓が決め、最小の大きさも窓に決め打ちで持たせる。中身から最小の大きさを受けると、
        // 画面が変わるたびに SwiftUI が窓全体の最小の大きさを測り直し、ページを移るたびのアプリの手間が5%ほど増えていた。
        hosting.sizingOptions = []
        // 画面の navigationTitle を窓の題名にする（hanectl ui が読む）。
        hosting.sceneBridgingOptions = [.title]
        window.contentViewController = hosting
        window.contentMinSize = BrowserWindow.minimumSize
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.center()
        window.delegate = self
        // 覚えていた位置があれば、そこへ動かす。
        slot.window = window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.activate(slot)
        slot.store?.isWindowKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        slot.store?.isWindowKey = false
    }

    func windowWillClose(_ notification: Notification) {
        slot.store?.isWindowKey = false
        // 閉じた窓は AppKit がしばらく掴んでいることがあり、覚える名前を握ったままだと次に開く窓が使えない。
        window.setFrameAutosaveName("")
        window.delegate = nil
        model.detach(slot)
        Task { @MainActor in
            Self.owners.removeAll { $0 === self }
        }
    }
}

/// ウインドウの位置と大きさを、プロファイルごとに覚えて次に開いたときに戻す。
///
/// macOS の再開を切ったので、そのままでは毎回既定の大きさで開く。AppKit の自動保存に任せる。
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
