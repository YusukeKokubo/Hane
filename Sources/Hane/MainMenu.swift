import AppKit

/// メニューバーとキーボードショートカット。
///
/// SwiftUI の Commands は中身を開く直前まで作り直さず、後から増えた項目のキーが効かなかったり、⌘W をタブで受けるのに
/// 並び順の裏技が要ったりしたので、AppKit のメニューを手で組む。項目の有効・無効、題名、チェックは
/// `validateMenuItem` で尋ねられたときに今のモデルから答え、中身が変わるメニューは `menuNeedsUpdate` で作り直す。
/// `NSApp.mainMenu` に入れるのは入口の側で、テストは `menu.performKeyEquivalent(with:)` を直に呼ぶ。
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation, NSMenuDelegate {
    let menu = NSMenu(title: "メインメニュー")
    /// システムが項目を足したり窓の一覧を並べたりする置き場。入口が `NSApp` に渡す。
    let servicesMenu = NSMenu(title: "サービス")
    let windowsMenu = NSMenu(title: "ウインドウ")
    let helpMenu = NSMenu(title: "ヘルプ")

    private let model: BrowserModel
    private let settings: SettingsStore
    private let settingsWindow: SettingsWindow
    private let bookmarksMenu = NSMenu(title: "ブックマーク")
    private let profilesMenu = NSMenu(title: "プロファイル")
    private let adBlockMenu = NSMenu(title: "広告ブロック")

    /// 最後に前へ出たプロファイルの窓のタブ管理。窓を移ったり閉じたりすると入れ替わるので、使うたびに今のものを読む。
    private var store: TabStore? { model.store }

    init(model: BrowserModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
        settingsWindow = SettingsWindow(settings: settings)
        super.init()
        menu.addItem(submenu(appMenu()))
        menu.addItem(submenu(fileMenu()))
        menu.addItem(submenu(editMenu()))
        menu.addItem(submenu(viewMenu()))
        menu.addItem(submenu(goMenu()))
        bookmarksMenu.delegate = self
        menu.addItem(submenu(bookmarksMenu))
        menu.addItem(submenu(profilesMenu))
        if model.contentBlocker != nil {
            adBlockMenu.delegate = self
            menu.addItem(submenu(adBlockMenu))
        }
        menu.addItem(submenu(windowMenu()))
        menu.addItem(submenu(helpMenu))
        // 開く前のキーの照合にも項目が要るので、最初の中身を作っておく。
        for dynamic in [bookmarksMenu, adBlockMenu] {
            menuNeedsUpdate(dynamic)
        }
        watchProfiles()
    }

    // MARK: 組み立て

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Hane")
        menu.addItem(item("Hane について", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: nil))
        menu.addItem(.separator())
        menu.addItem(item("設定…", #selector(showSettings), ","))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        services.submenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hane を隠す", #selector(NSApplication.hide(_:)), "h", target: nil))
        menu.addItem(item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: nil))
        menu.addItem(item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:)), target: nil))
        menu.addItem(.separator())
        menu.addItem(item("Hane を終了", #selector(NSApplication.terminate(_:)), "q", target: nil))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "ファイル")
        menu.addItem(item("新規タブ", #selector(newTab), "t"))
        // 開いた窓でプロファイルを選ぶ。
        menu.addItem(item("新規ウインドウ", #selector(newWindow), "n"))
        // 題名は場面で変わる（validateMenuItem）。
        menu.addItem(item("タブを閉じる", #selector(close), "w"))
        // Arc と同じく、タブが残っていても窓（プロファイル）ごと閉じる。
        menu.addItem(item("ウインドウを閉じる", #selector(closeWindow), "W"))
        menu.addItem(item("閉じたタブを開き直す", #selector(reopenClosedTab), "T"))
        menu.addItem(.separator())
        menu.addItem(item("場所を開く…", #selector(openLocation), "l"))
        return menu
    }

    private func editMenu() -> NSMenu {
        // 標準の項目は WKWebView と入力欄のどちらでも効くよう、受け手を決めずにレスポンダチェーンへ流す。
        let menu = NSMenu(title: "編集")
        menu.addItem(item("取り消す", Selector(("undo:")), "z", target: nil))
        menu.addItem(item("やり直す", Selector(("redo:")), "z", [.command, .shift], target: nil))
        menu.addItem(.separator())
        menu.addItem(item("カット", #selector(NSText.cut(_:)), "x", target: nil))
        menu.addItem(item("コピー", #selector(NSText.copy(_:)), "c", target: nil))
        menu.addItem(item("ペースト", #selector(NSText.paste(_:)), "v", target: nil))
        menu.addItem(item("ペーストしてスタイルを合わせる", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift], target: nil))
        menu.addItem(item("削除", #selector(NSText.delete(_:)), target: nil))
        menu.addItem(item("すべてを選択", #selector(NSText.selectAll(_:)), "a", target: nil))
        menu.addItem(.separator())
        menu.addItem(item("1Password で入力", #selector(fillPassword), "\\"))
        menu.addItem(item("1Password で入れる場所を教える…", #selector(teachPasswordPlace), "\\", [.command, .option]))
        menu.addItem(item("このサイトで教えた入れる場所を忘れる", #selector(forgetPasswordPlaces)))
        menu.addItem(.separator())
        let find = NSMenu(title: "検索")
        let finding: [(String, NSTextFinder.Action, String, NSEvent.ModifierFlags)] = [
            ("検索…", .showFindInterface, "f", .command),
            ("次を検索", .nextMatch, "g", .command),
            ("前を検索", .previousMatch, "g", [.command, .shift]),
            ("選択部分を検索に使用", .setSearchString, "e", .command),
        ]
        for (title, action, key, modifiers) in finding {
            let entry = item(title, #selector(NSTextView.performTextFinderAction(_:)), key, modifiers, target: nil)
            entry.tag = action.rawValue
            find.addItem(entry)
        }
        let findItem = NSMenuItem(title: "検索", action: nil, keyEquivalent: "")
        findItem.submenu = find
        menu.addItem(findItem)
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "表示")
        menu.addItem(item("フルスクリーンにする", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil))
        return menu
    }

    private func goMenu() -> NSMenu {
        let menu = NSMenu(title: "移動")
        menu.addItem(item("戻る", #selector(goBack), "["))
        menu.addItem(item("進む", #selector(goForward), "]"))
        menu.addItem(.separator())
        menu.addItem(item("ページを再読み込み", #selector(reload), "r"))
        menu.addItem(item("読み込みを中止", #selector(stopLoading), "."))
        menu.addItem(.separator())
        // 一つの項目にキーは一つしか付かないので、⌃Tab / ⌃⇧Tab は見えない代わりの項目で受ける。
        menu.addItem(item("次のタブ", #selector(nextTab), "]", [.command, .shift]))
        menu.addItem(hidden(item("次のタブ", #selector(nextTab), "\t", .control)))
        menu.addItem(item("前のタブ", #selector(previousTab), "[", [.command, .shift]))
        menu.addItem(hidden(item("前のタブ", #selector(previousTab), "\t", [.control, .shift])))
        // 本物の ⌃⇧Tab は文字が backtab になって届くので、その形でも受ける。
        menu.addItem(hidden(item("前のタブ", #selector(previousTab), "\u{19}", [.control, .shift])))
        menu.addItem(.separator())
        // バーに見えている並びのまま、左から数える。ブックマークとフォルダもタブと同じ一列の項目として扱う。
        for number in 1...9 {
            let entry = item(number == 9 ? "最後のタブ" : "バーの左から \(number) 番目", #selector(activateBarItem), "\(number)")
            entry.tag = number
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        // ページ自身が文字のキーで操作するサイトで、その場で外せるように。一覧は設定の窓で見る。題名とチェックは validateMenuItem。
        menu.addItem(item("このサイトではキー操作を使わない", #selector(toggleKeyNavigation)))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = windowsMenu
        menu.addItem(item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil))
        menu.addItem(item("拡大/縮小", #selector(NSWindow.performZoom(_:)), target: nil))
        menu.addItem(.separator())
        menu.addItem(item("すべてを手前に移動", #selector(NSApplication.arrangeInFront(_:)), target: nil))
        menu.addItem(item("すべての窓を閉じる", #selector(closeAllWindows), "w", [.command, .option]))
        return menu
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// 受け手を決める項目。標準の項目は `target: nil` でレスポンダチェーンへ流す。
    private func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    /// 自分の動作の項目。受け手を自分にする。
    private func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    // MARK: 中身が変わるメニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu {
        case bookmarksMenu: rebuildBookmarks()
        case adBlockMenu: rebuildAdBlock()
        default: break
        }
    }

    private func rebuildBookmarks() {
        let menu = bookmarksMenu
        menu.removeAllItems()
        // 題名は validateMenuItem。
        menu.addItem(item("ブックマークを追加…", #selector(editBookmark), "d"))
        let items = store?.bookmarks.items ?? []
        if !items.isEmpty {
            menu.addItem(.separator())
        }
        for entry in items {
            switch entry {
            case .bookmark(let bookmark):
                menu.addItem(bookmarkItem(bookmark))
            case .folder(let folder):
                let folderMenu = NSMenu(title: folder.name)
                for bookmark in folder.bookmarks {
                    folderMenu.addItem(bookmarkItem(bookmark))
                }
                let folderItem = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
                folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                folderItem.submenu = folderMenu
                menu.addItem(folderItem)
            }
        }
    }

    private func bookmarkItem(_ bookmark: Bookmark) -> NSMenuItem {
        let entry = item(bookmark.title, #selector(openBookmark(_:)))
        entry.representedObject = bookmark.id
        return entry
    }

    /// プロファイルの一覧が変わったら作り直す。
    ///
    /// 項目に ⌃1〜9 を付けるので、メニューを開く前のキーの照合に間に合わせる必要がある。AppKit はキーの照合の前に
    /// `menuNeedsUpdate` を呼ばなかった（メニューを組んだあとに足したプロファイルの ⌃2 が効かなかった）。
    private func watchProfiles() {
        withObservationTracking {
            rebuildProfiles()
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchProfiles() }
        }
    }

    /// 選ぶと、そのプロファイルの窓があれば前に出し、なければ新しい窓で開く（今の窓のタブは閉じない）。
    /// 手前がプロファイルを選ぶ前の窓なら、その窓に出す。チェックは validateMenuItem。
    private func rebuildProfiles() {
        let menu = profilesMenu
        menu.removeAllItems()
        for (index, name) in model.names.enumerated() {
            let entry = item(BrowserModel.title(for: name), #selector(openProfile(_:)), index < 9 ? "\(index + 1)" : "", .control)
            entry.representedObject = name
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("新しいプロファイル…", #selector(newProfile)))
    }

    private func rebuildAdBlock() {
        guard let blocker = model.contentBlocker else { return }
        let menu = adBlockMenu
        menu.removeAllItems()
        // 選ぶ操作はページの中で拾うのでメニューからは始められないが、やり方をここで見せる。
        menu.addItem(NSMenuItem(title: "⌥右クリックで要素を選んで隠す", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(item("このサイトで隠した要素を元に戻す", #selector(unhideElements)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: blocker.filterSummary, action: nil, keyEquivalent: ""))
    }

    // MARK: 有効・無効と題名

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let selected = store?.selected
        switch item.action {
        case #selector(close):
            switch closeTarget() {
            case .tab:
                item.title = "タブを閉じる"
                return true
            case .window:
                item.title = "ウインドウを閉じる"
                return true
            case nil:
                item.title = "ウインドウを閉じる"
                return false
            }
        case #selector(reopenClosedTab):
            return store?.closedTabs.isEmpty == false
        case #selector(fillPassword), #selector(teachPasswordPlace), #selector(reload):
            return selected?.hasContent == true
        case #selector(forgetPasswordPlaces):
            let count = passwordPlaceCount()
            item.title = count > 0 ? "このサイトで教えた入れる場所を忘れる（\(count)件）" : "このサイトで教えた入れる場所を忘れる"
            return count > 0
        case #selector(goBack):
            return selected?.canGoBack == true
        case #selector(goForward):
            return selected?.canGoForward == true
        case #selector(stopLoading):
            return selected?.isLoading == true
        case #selector(toggleKeyNavigation):
            let host = currentHost
            item.title = host.isEmpty ? "このサイトではキー操作を使わない" : "\(host) ではキー操作を使わない"
            item.state = !host.isEmpty && settings.isExcludedFromKeyNavigation(host) ? .on : .off
            return !host.isEmpty && settings.usesKeyNavigation
        case #selector(editBookmark):
            let exists = store.flatMap { store in selected.flatMap(store.bookmark(for:)) } != nil
            item.title = exists ? "ブックマークを編集…" : "ブックマークを追加…"
            return selected?.url != nil
        case #selector(openProfile(_:)):
            item.state = (item.representedObject as? String) == model.current ? .on : .off
            return true
        case #selector(newProfile):
            return model.focusedWindow != nil
        case #selector(unhideElements):
            let count = hiddenElementCount()
            item.title = count > 0 ? "このサイトで隠した要素を元に戻す（\(count)件）" : "このサイトで隠した要素を元に戻す"
            return count > 0
        case #selector(closeWindow):
            return frontClosableWindow() != nil
        case #selector(closeAllWindows):
            return !closableWindows().isEmpty
        default:
            // 窓がない（タブ管理がない）ときも有効のままにする。押しても何も起きない。
            return true
        }
    }

    private var currentHost: String { store?.selected?.url?.host() ?? "" }

    private var currentSite: String? { store?.selected?.url.flatMap(HiddenElementStore.site(for:)) }

    private func passwordPlaceCount() -> Int {
        guard let site = currentSite, let store else { return 0 }
        return store.passwordFill.places.places(on: site).count
    }

    private func hiddenElementCount() -> Int {
        guard let site = currentSite, let blocker = model.contentBlocker else { return 0 }
        return blocker.hidden.selectors(on: site).count
    }

    // MARK: 閉じる

    private enum CloseTarget {
        case tab(TabStore)
        case window(NSWindow)
    }

    /// ⌘W の相手。手前の窓がプロファイルを出している本体の窓ならタブ、設定の窓やプロファイルを選ぶ前の窓、小窓ならその窓。
    /// シートやポップオーバー（親のある窓）が手前のときは、その下の本体の窓のタブを閉じる。
    private func closeTarget() -> CloseTarget? {
        if let front = NSApp.orderedWindows.first(where: \.isVisible), front.parent == nil, front.sheetParent == nil {
            let slot = model.windows.first { $0.window === front }
            if slot?.profile == nil { return .window(front) }
        }
        return store.map(CloseTarget.tab)
    }

    @objc private func close() {
        switch closeTarget() {
        case .tab(let store):
            // 最後のタブなら窓ごと閉じる。
            if !store.closeSelected() {
                model.currentWindow?.close()
            }
        case .window(let window):
            window.performClose(nil)
        case nil:
            break
        }
    }

    /// シートやポップオーバーのような、ほかの窓に付いている窓は親と一緒に閉じるので数えない。
    private func closableWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.parent == nil && $0.sheetParent == nil && $0.styleMask.contains(.closable) }
    }

    /// シートやポップオーバーが手前なら、その下の窓を閉じる。
    private func frontClosableWindow() -> NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && $0.parent == nil && $0.sheetParent == nil && $0.styleMask.contains(.closable) }
    }

    @objc private func closeWindow() {
        frontClosableWindow()?.performClose(nil)
    }

    @objc private func closeAllWindows() {
        for window in closableWindows() {
            window.performClose(nil)
        }
    }

    // MARK: 動作

    @objc private func showSettings() { settingsWindow.show() }
    @objc private func newTab() { _ = store?.newTab() }
    @objc private func newWindow() { _ = model.openEmptyWindow() }
    @objc private func reopenClosedTab() { store?.reopenClosedTab() }
    @objc private func openLocation() { store?.focusAddressBar() }
    @objc private func fillPassword() { store?.passwordFill.start(on: store?.selected) }
    @objc private func teachPasswordPlace() { store?.passwordFill.start(on: store?.selected, teaching: true) }

    @objc private func forgetPasswordPlaces() {
        guard let site = currentSite else { return }
        store?.passwordFill.places.removeAll(on: site)
    }

    @objc private func goBack() { store?.selected?.goBack() }
    @objc private func goForward() { store?.selected?.goForward() }
    @objc private func reload() { store?.selected?.reload() }
    @objc private func stopLoading() { store?.selected?.stop() }
    @objc private func nextTab() { store?.select(offset: 1) }
    @objc private func previousTab() { store?.select(offset: -1) }
    @objc private func activateBarItem(_ sender: NSMenuItem) { store?.activateBarItem(number: sender.tag) }

    @objc private func toggleKeyNavigation() {
        let host = currentHost
        guard !host.isEmpty else { return }
        settings.setKeyNavigation(excluded: !settings.isExcludedFromKeyNavigation(host), on: host)
    }

    @objc private func editBookmark() { store?.requestBookmarkEditor() }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        _ = store?.activate(bookmark: id)
    }

    @objc private func openProfile(_ sender: NSMenuItem) {
        // 押しっぱなしの繰り返しで何度も起こさない。
        // メニューから選んだときの事象はキーではなく、isARepeat を尋ねると例外になる。
        if let event = NSApp?.currentEvent, event.type == .keyDown, event.isARepeat { return }
        guard let name = sender.representedObject as? String else { return }
        model.open(name)
    }

    @objc private func newProfile() { model.beginCreating() }

    @objc private func unhideElements() {
        guard let site = currentSite, let tab = store?.selected, let blocker = model.contentBlocker else { return }
        Task {
            await blocker.unhideAll(on: site)
            tab.reload()
        }
    }
}
