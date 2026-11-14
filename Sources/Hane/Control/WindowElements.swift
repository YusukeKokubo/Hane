import AppKit
import ApplicationServices
import WebKit

/// 窓の枠まわり（タブバー、ナビゲーションの段、ポップオーバー、シート）の部品を番号つきで一覧し、
/// マウスで触ったのと同じ道筋で操作する。
///
/// 部品はアプリ自身のアクセシビリティの木から拾う。外のプロセスから辿るには権限が要るが、
/// 自分の木を中から辿るだけなら要らない。ただし SwiftUI のタブやブックマークは `onTapGesture` で
/// 押すので、押す操作（AXPress）を出していない。そのため操作は部品の真ん中へマウスの事象を作って渡す。
///
/// ドラッグは持たない。作ったマウスの事象ではシステムのドラッグが始まらず、運ぶ中身を載せた
/// ドラッグの情報を落とし先へ直に渡しても SwiftUI は受け付けず、その後の描画でアプリが落ちた。
/// 落としたときの並べ替えは `TabStore.drop` の単体テストで見ている。
@MainActor
final class WindowElements {
    private struct Element {
        let object: NSObject
        let window: NSWindow
        let kind: String
        let name: String
        /// 一覧に出した行。名前が重なったときに候補として見せる。
        let line: String

        var label: String { "\(kind) \"\(name)\"" }
    }

    /// 部品から出るメニュー。右クリックのメニューか、選択欄（ポップアップボタン）の選択肢。
    struct ElementMenu {
        let label: String
        /// 選べる項目。区切りと隠れた項目は除く。
        let items: [NSMenuItem]
        /// 選択欄なら、今選ばれている項目。
        let selected: NSMenuItem?
        let choose: (NSMenuItem) -> Void
    }

    /// 直前の一覧。番号はここへの添字に1を足したもの。
    private var elements: [Element] = []
    /// 相手にする本体の窓。窓が何枚あっても、外部操作は今のプロファイルの窓を相手にする。
    private let mainWindow: @MainActor () -> NSWindow?

    init(mainWindow: @escaping @MainActor () -> NSWindow? = { nil }) {
        self.mainWindow = mainWindow
    }

    /// 一覧に出す役割と、出すときの呼び名。画像や入れ物は数が多いわりに触る先にならないので出さない。
    private static let kinds: [String: String] = [
        "AXButton": "button", "AXStaticText": "text", "AXTextField": "textfield",
        "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "popup",
        "AXMenuButton": "menubutton", "AXLink": "link", "AXSlider": "slider",
    ]

    /// 画面の側でアクセシビリティの識別子を付けた、バーの項目のまとまり。中の部品ではなく項目ごと一行に出す。
    private static let itemKinds: Set<String> = ["tab", "bookmark", "folder"]

    // MARK: 一覧

    func snapshot() async throws -> String {
        Self.wakeAccessibility()
        // 起動の直後は窓がまだないので、出るまで少し待つ。
        for _ in 0..<30 {
            if let lines = try? collectAll(), !elements.isEmpty { return lines }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return try collectAll()
    }

    private static var accessibilityIsAwake = false

    /// SwiftUI はアクセシビリティの道具（VoiceOver など）から問い合わせが来るまで木を作らず、
    /// 中から辿っても空のまま。外の道具と同じ API で自分に一度問い合わせて、木を作らせる。
    /// `open` で起動すると別の常駐アプリが問い合わせるのか木ができるが、直に起動すると（verify.sh）できない。
    private static func wakeAccessibility() {
        guard !accessibilityIsAwake else { return }
        accessibilityIsAwake = true
        var children: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXChildrenAttribute as CFString, &children)
    }

    private func collectAll() throws -> String {
        let windows = Self.windows(main: mainWindow())
        guard let main = windows.first?.window else { throw ControlError("窓が出ていない。") }
        elements = []
        var lines: [String] = []
        for (window, kind) in windows {
            lines.append("\(kind):")
            // 別に開いた窓の部品は、その窓の左上から測る。
            let origin = window === main || window.parent != nil || window.sheetParent != nil ? main : window
            if let content = window.contentView {
                collect(content, in: window, relativeTo: origin, depth: 0, insideItem: false, into: &lines)
            }
        }
        lines.append("（座標は窓の左上から。window-screenshot の画像と同じ向き）")
        return lines.joined(separator: "\n")
    }

    /// 窓と、その上に出ているシートやポップオーバー、本体の窓より手前にある別の窓（設定の窓、ほかのプロファイルの窓など）。
    /// キーを受けるのは後ろにあるものほど手前。本体の窓は `main`（今のプロファイルの窓）で、なければ識別子で探す。
    static func windows(main preferred: NSWindow?) -> [(window: NSWindow, kind: String)] {
        let visible = NSApp.windows.filter(\.isVisible)
        // 設定の窓も本体の窓になれるので、本体の窓は識別子で選ぶ。本体の窓は MainWindow が識別子を付ける。
        guard let main = preferred.flatMap({ visible.contains($0) ? $0 : nil })
            ?? visible.first(where: { $0.identifier?.rawValue.hasPrefix(HaneApp.windowID) == true })
            ?? visible.first(where: \.canBecomeMain)
        else { return [] }
        var result: [(NSWindow, String)] = [(main, "window")]
        // フォルダの一覧から開く編集欄のように、ポップオーバーの上に重なるものは孫の窓になる。
        func appendChildren(of window: NSWindow) {
            for child in window.childWindows ?? [] where child.isVisible {
                result.append((child, String(describing: type(of: child)).contains("Popover") ? "popover" : "child window"))
                appendChildren(of: child)
            }
        }
        appendChildren(of: main)
        if let sheet = main.attachedSheet, sheet.isVisible {
            result.append((sheet, "sheet"))
        }
        // 手前から並ぶので、奥のものから足して、いちばん手前を最後にする。
        let front = NSApp.orderedWindows.prefix { $0 !== main }.reversed().filter { window in
            window.isVisible && window.parent == nil && window.sheetParent == nil
                && !result.contains { $0.0 === window }
        }
        for window in front {
            result.append((window, "window \"\(window.title)\""))
            appendChildren(of: window)
        }
        return result
    }

    private func collect(
        _ element: Any, in window: NSWindow, relativeTo main: NSWindow, depth: Int, insideItem: Bool, into lines: inout [String]
    ) {
        guard depth < 40, let object = element as? NSObject else { return }
        // ページの中身は snapshot の受け持ち。
        if object is WKWebView { return }

        let role = Self.attribute(object, "accessibilityRole") as? String ?? ""
        let identifier = Self.text(object, "accessibilityIdentifier")
        var kind = Self.kinds[role]
        var childrenInsideItem = insideItem
        if role == "AXGroup", Self.itemKinds.contains(identifier) {
            kind = identifier
            childrenInsideItem = true
        } else if insideItem, role == "AXStaticText" {
            // 項目の題名は項目の行に出ているので重ねない。中のボタンは別に出す。
            kind = nil
        }

        let frame = Self.frame(of: object)
        if let kind, frame.width > 0, frame.height > 0 {
            let label = Self.text(object, "accessibilityLabel")
            let title = Self.text(object, "accessibilityTitle")
            let value = Self.text(object, "accessibilityValue")
            let help = Self.text(object, "accessibilityHelp")
            let placeholder = Self.text(object, "accessibilityPlaceholderValue")
            let name = [label, title, kind == "textfield" ? "" : value, placeholder].first { !$0.isEmpty } ?? ""

            var line = "[\(elements.count + 1)] \(kind) \"\(Self.clip(name, 80))\""
            if kind == "textfield" { line += " value=\"\(Self.clip(value, 80))\"" }
            if !help.isEmpty, help != name { line += " help=\"\(Self.clip(help, 80))\"" }
            if Self.attribute(object, "accessibilityEnabled") as? Bool == false { line += " (disabled)" }
            let x = Int(frame.minX - main.frame.minX), y = Int(main.frame.maxY - frame.maxY)
            line += " @\(x),\(y) \(Int(frame.width))x\(Int(frame.height))"
            elements.append(Element(object: object, window: window, kind: kind, name: name, line: line))
            lines.append("  " + line)
        }
        for child in Self.attribute(object, "accessibilityChildren") as? [Any] ?? [] {
            collect(child, in: window, relativeTo: main, depth: depth + 1, insideItem: childrenInsideItem, into: &lines)
        }
    }

    /// 番号か名前で指された部品の番号。
    ///
    /// 名前なら今の窓から一覧を取り直して探す（番号は振り直しになる）。並びが変わったあとに古い番号で
    /// 別の部品を押す取り違えを避けるため。`tab:Second` のように種類を前に付けると、同じ名前を見分けられる。
    func resolve(_ reference: String) async throws -> Int {
        if let number = Int(reference) { return number }
        var kind: String?
        var name = reference
        if let colon = reference.firstIndex(of: ":") {
            let prefix = String(reference[..<colon])
            if Self.kinds.values.contains(prefix) || Self.itemKinds.contains(prefix) {
                kind = prefix
                name = String(reference[reference.index(after: colon)...])
            }
        }
        _ = try await snapshot()
        let matches = elements.indices.filter { elements[$0].name == name && (kind == nil || elements[$0].kind == kind) }
        switch matches.count {
        case 1:
            return matches[0] + 1
        case 0:
            throw ControlError("「\(reference)」という部品はない。`ui-snapshot` で名前を確かめること。")
        default:
            throw ControlError("「\(reference)」に合う部品が \(matches.count) 個ある。番号か、tab:名前 のように種類を付けて指すこと。\n"
                + matches.map { "  " + elements[$0].line }.joined(separator: "\n"))
        }
    }

    // MARK: 操作

    /// 左ボタンで押して離す。
    ///
    /// ボタンは押されると離されるまで自分で事象を待つので、離す事象を先に待ち行列へ積んでから押す。
    /// 窓へ直に渡すので、アプリが裏にいても前には出ない。
    func click(_ number: Int) throws -> String {
        let (element, window, point) = try target(number)
        // 押すとメニューが出て、閉じるまでメインスレッドが止まり、応答を返せなくなる。
        guard element.kind != "popup", element.kind != "menubutton" else {
            throw ControlError("\(element.label) は押すとメニューが出る。`ui-menu \(number)` で選択肢を見て選ぶこと。")
        }
        let up = try Self.mouseEvent(.leftMouseUp, at: point, in: window)
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(try Self.mouseEvent(.leftMouseDown, at: point, in: window))
        return "clicked \(element.label)"
    }

    /// ポインタを部品の上へ動かす。乗せている間だけ出る部品（閉じるボタンなど）を出すため。
    func hover(_ number: Int) throws -> String {
        let (element, window, point) = try target(number)
        window.sendEvent(try Self.mouseEvent(.mouseMoved, at: point, in: window))
        // SwiftUI の onHover は、アプリが前面にいるときしか乗せた知らせを受けない。
        return "hovering \(element.label)"
            + (NSApp.isActive ? "" : "\n（アプリが裏にいるので、乗せたときだけ出る表示は出ない。前面にいるときに試すこと）")
    }

    /// 部品から出るメニュー。選択欄ならその選択肢、ほかは右クリックで出るメニュー。
    ///
    /// どちらも出すと閉じるまでメインスレッドが止まるので、出さずに中身だけを引き、選ぶときは項目の動作を直に呼ぶ。
    /// SwiftUI が自分で描く選択欄だけは出さずに引けないので、出してすぐ閉じる（`menuShown`）。
    func menu(_ number: Int) async throws -> ElementMenu {
        let (element, window, point) = try target(number)
        guard let hit = Self.view(at: point, in: window) else {
            throw ControlError("\(element.label) の位置に部品がない。")
        }
        if let popUp = Self.popUpButton(for: element.object) ?? Self.ancestor(of: hit, as: NSPopUpButton.self),
           let menu = popUp.menu {
            menu.update()
            // 選択欄の項目は、選ばれたときに選択を移してから選択欄の動作を送るように作られている。
            // 選択欄の動作だけを送っても SwiftUI の値は変わらないので、項目の動作を呼ぶ。
            return ElementMenu(label: element.label, items: Self.choosable(menu), selected: popUp.selectedItem) { item in
                menu.performActionForItem(at: menu.index(of: item))
            }
        }
        if element.kind == "popup" || element.kind == "menubutton", let menu = await Self.menuShown(by: element.object) {
            return ElementMenu(
                label: element.label, items: Self.choosable(menu), selected: menu.items.first { $0.state == .on }
            ) { item in
                menu.performActionForItem(at: menu.index(of: item))
            }
        }
        let event = try Self.mouseEvent(.rightMouseDown, at: point, in: window)
        var view: NSView? = hit
        while let current = view {
            if let menu = current.menu(for: event) {
                menu.update()
                return ElementMenu(label: element.label, items: Self.choosable(menu), selected: nil) { item in
                    menu.performActionForItem(at: menu.index(of: item))
                }
            }
            view = current.superview
        }
        throw ControlError("\(element.label) には右クリックのメニューがない。")
    }

    /// 窓の座標の点にある、いちばん奥の部品。`hitTest` は親の座標で点を受け取る。
    private static func view(at point: NSPoint, in window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }

    /// SwiftUI が自分で描く選択欄のメニュー。
    ///
    /// macOS 27.2（Xcode 27.2）で、ポップオーバーの中の `Picker` は `NSPopUpButton` を持たなくなり、
    /// メニューは出すときに初めて作られるので、出さずに引く道がない。そこでアクセシビリティの押す動作で
    /// 出させ（「メニューを出す」動作は false を返して何もしなかった）、`MenuCatcher` で出たそばから閉じて、
    /// そのメニューを持ち帰る。持ち主の画面には一瞬メニューが出る。
    private static func menuShown(by object: NSObject) async -> NSMenu? {
        let catcher = MenuCatcher()
        defer { catcher.stop() }
        // SwiftUI の部品は動作を持っていても NSAccessibilityProtocol を名乗らないので、名前で呼ぶ。
        guard (object as AnyObject).accessibilityPerformPress?() == true else { return nil }
        // メニューは押す動作から返ったあとで出る。閉じるのは一拍おいてからなので、それも待つ。
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while catcher.menu == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let menu = catcher.menu else { return nil }
        try? await Task.sleep(for: .milliseconds(50))
        return menu
    }

    private static func popUpButton(for object: NSObject) -> NSPopUpButton? {
        (object as? NSPopUpButton) ?? ((object as? NSCell)?.controlView as? NSPopUpButton)
    }

    private static func ancestor<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        var current: NSView? = view
        while let candidate = current {
            if let match = candidate as? T { return match }
            current = candidate.superview
        }
        return nil
    }

    private static func choosable(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
    }

    private func target(_ number: Int) throws -> (Element, NSWindow, NSPoint) {
        guard elements.indices.contains(number - 1) else {
            throw ControlError("部品 \(number) はない。先に `ui-snapshot` で一覧を取ること。")
        }
        let element = elements[number - 1]
        let frame = Self.frame(of: element.object)
        // 消えた部品は大きさが0になるか、窓が閉じている。
        guard element.window.isVisible, frame.width > 0, frame.height > 0 else {
            throw ControlError("部品 \(number)（\(element.label)）はもう出ていない。`ui-snapshot` を取り直すこと。")
        }
        let center = element.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        return (element, element.window, center)
    }

    // MARK: 下回り

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0
        ) else { throw ControlError("マウスの事象を作れない。") }
        return event
    }

    /// アクセシビリティの属性を、名前で引く。
    ///
    /// SwiftUI の部品は AppKit の非公開の型なので、プロトコルの任意の要件として呼ぶ代わりに
    /// Objective-C の名前で引く。持っていない属性は nil。
    private static func attribute(_ object: NSObject, _ key: String) -> Any? {
        let getter = key == "accessibilityEnabled" ? "isAccessibilityEnabled" : key
        guard object.responds(to: NSSelectorFromString(getter)) else { return nil }
        return object.value(forKey: key)
    }

    private static func text(_ object: NSObject, _ key: String) -> String {
        switch attribute(object, key) {
        case let string as String: string
        case let attributed as NSAttributedString: attributed.string
        case let number as NSNumber: number.stringValue
        default: ""
        }
    }

    private static func frame(of object: NSObject) -> CGRect {
        (object as? NSAccessibilityElementProtocol)?.accessibilityFrame() ?? .zero
    }

    private static func clip(_ text: String, _ length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? flat.prefix(length - 1) + "…" : flat
    }
}
