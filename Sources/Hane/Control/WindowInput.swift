import AppKit
import Foundation

/// 窓まわり（メニュー、バー、シート、ポップオーバー）へのキーと文字の入力と、窓そのものの扱い（大きさ、外観、
/// 前に出す、撮る）。
///
/// アプリが裏にいるとシステムはキーを届けず、前に出すと持ち主の作業を遮るので、本物のキーが通る道を
/// ここで自分で辿って手渡しする。AppKit の事象を自前で配る綱引きはここに集めて、ほかへ漏らさない。
/// 窓の部品の一覧とマウスでの操作は `WindowElements` の受け持ち。
@MainActor
final class WindowInput {
    private let model: BrowserModel

    init(model: BrowserModel) {
        self.model = model
    }

    /// 相手にする本体の窓（今のプロファイルの窓）。
    func mainWindow() -> NSWindow? {
        WindowElements.windows(main: model.currentWindow).first?.window
    }

    /// 裏にいるとき、前に出ていればキーを受けたはずのウインドウ。シートやポップオーバーが出ていればそちら。
    private func backgroundKeyTarget() -> NSWindow? {
        WindowElements.windows(main: model.currentWindow).last?.window
    }

    // MARK: キーと文字

    /// キーを送り、画面の更新とポップオーバーの出し入れを待つ。キーで開いた窓は本体の窓の上に重ねる。
    func pressKey(_ spec: String) async throws {
        let before = arrangement()
        try sendKey(spec)
        try? await Task.sleep(for: .milliseconds(300))
        orderNewWindowsFront(since: before)
    }

    /// ページの外（メニューやバー）へ、利用者が打ったのと同じ道筋でキーを送る。
    ///
    /// 本物のキーが通る順（局所モニタ、窓の部品のキー、メニュー、ウインドウ）をここで辿って手渡しする。
    /// 裏にいるとキーを受けるウインドウがなく、自分から前に出ることもシステムに断られるため。
    /// 前面にいるときも同じ道を通す。待ち行列に積むと、アラートの Return と Esc が効かなかった。
    private func sendKey(_ spec: String) throws {
        let (flags, keyCode, characters) = try KeySpec.windowKey(from: spec)
        guard let window = NSApp.keyWindow ?? backgroundKeyTarget() else {
            throw ControlError("ウインドウがない。")
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { throw ControlError("キーの事象を作れない: \(spec)") }

        if LocalShortcuts.handle(event, model: model) { return }
        // 離す事象がないと、ページの文字のキーでの操作（KeyNavigation）が押しっぱなしとみなしてスクロールを流し続ける。
        // 修飾なしの文字は Web ビューが performKeyEquivalent で拾ってページへ渡すので、どの道でも最後に離す。
        // 押す事象と同じく待ち行列に積まず直に渡す。
        defer {
            if let release = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ) { window.sendEvent(release) }
        }
        // メニューより先に窓の部品へ渡す。アラートや編集欄の既定のボタン（Return）とキャンセル（Esc）はここで拾われる。
        if window.performKeyEquivalent(with: event) { return }
        // 既定のボタン（アラートの OK など）の Return は、窓がキーを受ける窓のときしか効かない。裏にいるアプリの窓は
        // キーを受ける窓になれないので、裏ではシートが Return で閉じなかった（Esc のような、ボタン自身に割り当てたキーは効く）。
        // 前で打ったときと同じく、既定のボタンを押す。
        if !window.isKeyWindow, flags.isEmpty, characters == "\r", let button = window.defaultButtonCell {
            button.performClick(nil)
            return
        }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        window.sendEvent(event)
    }

    /// フォーカスのある入力欄へ、1文字ずつ打ち込んだのと同じように差し込む。
    ///
    /// キーの事象を作って送ると、持ち主の入力方式が日本語のときに仮名へ変換されてしまうので、
    /// 入力欄の編集部品（フィールドエディタ）へ文字を直接入れる。文字ごとに間を置き、
    /// 画面が1文字ずつ変化を受け取れるようにする。
    func typeText(_ text: String, replacing: Bool) async throws {
        let window = NSApp.keyWindow ?? backgroundKeyTarget()
        if replacing {
            guard let editor = window?.firstResponder as? NSTextView else {
                throw ControlError("文字を受け付ける入力欄にフォーカスがない。")
            }
            editor.selectAll(nil)
        }
        for character in text {
            guard let editor = window?.firstResponder as? NSTextView else {
                throw ControlError("文字を受け付ける入力欄にフォーカスがない。")
            }
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    // MARK: 新しい窓

    /// 何かで新しい窓が開く前の、窓の並び。
    struct Arrangement {
        fileprivate let windows: Set<ObjectIdentifier>
        fileprivate let front: NSWindow?
    }

    func arrangement() -> Arrangement {
        Arrangement(windows: Set(NSApp.windows.map(ObjectIdentifier.init)), front: mainWindow())
    }

    /// キーで開いた窓（⌘N の窓など）を、本体の窓のすぐ上に重ねる。
    ///
    /// アプリが裏にいると、一度シートや選択欄のメニューを出したあとは、新しい窓が本体の窓の裏に置かれた
    /// （macOS 27.2 で確かめた。出す前なら手前に来る）。裏に置かれると ui-snapshot に出ず、前で打ったときと
    /// 振る舞いが変わるので、前で打ったときと同じく手前に並べる。`orderFront` や `makeKeyAndOrderFront` は
    /// 50 ミリ秒もたたずに本体の窓の裏へ戻されたが、本体の窓を指して上に重ねれば残った（小窓と同じやり方）。
    /// ほかのアプリの窓より前には出さない。前面にいるときは AppKit が手前に置くので何もしない。
    /// キーで開いた窓（⌘N や、⌃数字で開いたプロファイル）が新しい窓を前の窓の裏に置かれないよう、開く前に前にいた窓の上に重ねる。
    func orderNewWindowsFront(since before: Arrangement) {
        guard !NSApp.isActive, let main = before.front else { return }
        for window in NSApp.windows where !before.windows.contains(ObjectIdentifier(window)) {
            guard window.isVisible, window.parent == nil, window.sheetParent == nil, window.canBecomeMain else { continue }
            window.order(.above, relativeTo: main.windowNumber)
        }
    }

    /// 新しい窓に開くよう頼んだプロファイルが、窓に出て AppKit の窓に置かれるまで待つ。
    func waitForWindow(showing name: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !model.isShown(name) {
            guard clock.now < deadline else {
                throw ControlError("「\(name)」の窓が 10 秒たっても開かなかった。")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // AppKit の窓は、窓が出た知らせより一巡り遅れて結ばれる。テストの窓は AppKit の窓を持たないので、待ちきらずに進む。
        let bound = clock.now + .seconds(1)
        while model.window(showing: name)?.window == nil, clock.now < bound {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: 窓そのもの

    /// 左上を動かさずに大きさだけ変える（AppKit の座標は左下から測る）。
    func resize(_ window: NSWindow, width: Int, height: Int) {
        var frame = window.frame
        frame.origin.y += frame.height - CGFloat(height)
        frame.size = CGSize(width: width, height: height)
        window.setFrame(frame, display: true)
    }

    /// 外観を変える（`name` が nil なら今のまま）。今の外観を返す。
    func appearance(_ name: String?) throws -> String {
        if let name {
            switch name {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "system": NSApp.appearance = nil
            default: throw ControlError("外観は dark、light、system のどれか: \(name)")
            }
        }
        let effective = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        return "appearance: \(effective)" + (NSApp.appearance == nil ? "（システムに従う）" : "（このアプリだけ固定。appearance system で戻す）")
    }

    /// 同じ実体を二重に起動しようとしたときに、後から起きた方が頼んでくる。最小化や隠れていれば戻す。
    func activate() {
        NSApp.unhide(nil)
        if let window = model.currentWindow ?? NSApp.windows.first(where: \.canBecomeMain) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// 窓の中身をアプリ自身に描かせて画像にする。画面収録の権限が要らず、窓が裏にいても撮れる。
    ///
    /// `cacheDisplay` で描かせるとバーの背景が明るい外観の白で塗られて実物と違ってしまうので、
    /// Core Animation の層をそのまま描く。窓の背景の素材は中身の外にあって写らないので、
    /// 外観に合わせた窓の背景色を下に敷く。
    func screenshot(to path: String?) throws -> String {
        guard let window = mainWindow(), let view = window.contentView, let layer = view.layer else {
            throw ControlError("窓が出ていない。")
        }
        view.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ControlError("窓を画像にできなかった。")
        }
        let cg = context.cgContext
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            // 外観で変わる色は、外観を当てた中で具体的な色に直さないと明るい外観の色になる。
            cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            cg.scaleBy(x: scale, y: scale)
            if view.isFlipped {
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
            }
            layer.render(in: cg)
        }
        bitmap.size = size

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ControlError("窓を画像にできなかった。")
        }
        let destination = URL(filePath: path ?? NSTemporaryDirectory() + "hane-window-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: destination)
        let appearance = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        return destination.path(percentEncoded: false) + "\nappearance: \(appearance)"
    }
}
