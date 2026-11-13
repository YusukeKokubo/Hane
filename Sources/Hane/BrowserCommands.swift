import AppKit
import SwiftUI

/// メニューとキーボードショートカット。
struct BrowserCommands: Commands {
    let model: BrowserModel

    /// 切り替えるとタブ管理が入れ替わるので、使うたびに今のものを読む。
    private var store: TabStore { model.store }

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        // 標準の「閉じる」（Cmd+W）より前に置くことで、Cmd+W をタブ側で受ける。
        CommandGroup(replacing: .newItem) {
            Button("新規タブ") { store.newTab() }
                .keyboardShortcut("t")
            Button("タブを閉じる") { closeTab() }
                .keyboardShortcut("w")
            Divider()
            Button("場所を開く…") { store.focusAddressBar() }
                .keyboardShortcut("l")
        }

        CommandMenu("移動") {
            Button("戻る") { store.selected?.goBack() }
                .keyboardShortcut("[")
                .disabled(store.selected?.canGoBack != true)
            Button("進む") { store.selected?.goForward() }
                .keyboardShortcut("]")
                .disabled(store.selected?.canGoForward != true)
            Divider()
            Button("ページを再読み込み") { store.selected?.reload() }
                .keyboardShortcut("r")
                .disabled(store.selected?.hasContent != true)
            Button("読み込みを中止") { store.selected?.stop() }
                .keyboardShortcut(".")
                .disabled(store.selected?.isLoading != true)
            Divider()
            // ⌃Tab / ⌃⇧Tab でも移れる（LocalShortcuts が拾う）。
            Button("次のタブ") { store.select(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("前のタブ") { store.select(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            // バーに見えている並びのまま、左から数える。ブックマークとフォルダもタブと同じ一列の項目として扱う。
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "最後のタブ" : "バーの左から \(number) 番目") { store.activateBarItem(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }

        // バーと同じものを、キーボードやメニューからも選べるようにする。
        CommandMenu("ブックマーク") {
            Button(hasBookmarkForSelectedPage ? "ブックマークを編集…" : "ブックマークを追加…") {
                store.requestBookmarkEditor()
            }
            .keyboardShortcut("d")
            .disabled(store.selected?.url == nil)
            if !store.bookmarks.items.isEmpty {
                Divider()
            }
            ForEach(store.bookmarks.items) { item in
                switch item {
                case .bookmark(let bookmark):
                    Button(bookmark.title) { store.activate(bookmark: bookmark.id) }
                case .folder(let folder):
                    Menu {
                        ForEach(folder.bookmarks) { bookmark in
                            Button(bookmark.title) { store.activate(bookmark: bookmark.id) }
                        }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
            }
        }

        // 選ぶと、今のタブを閉じて、そのプロファイルのタブをこの窓に戻す。
        // ⌃1〜9 はどのキーで移るかを見せるため。項目は後から増えるので、キーそのものは LocalShortcuts が拾う。
        CommandMenu("プロファイル") {
            ForEach(Array(model.names.enumerated()), id: \.element) { index, name in
                let toggle = Toggle(BrowserModel.title(for: name), isOn: Binding(
                    get: { name == model.current },
                    set: { _ in model.open(name) }
                ))
                if index < 9 {
                    toggle.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                } else {
                    toggle
                }
            }
            Divider()
            Button("新しいプロファイル…") { model.isCreating = true }
        }

        if let blocker = store.contentBlocker {
            CommandMenu("広告ブロック") {
                // 選ぶ操作はページの中で拾うのでメニューからは始められないが、やり方をここで見せる。
                Text("⌥右クリックで要素を選んで隠す")
                Divider()
                let site = store.selected?.url.flatMap(HiddenElementStore.site(for:))
                let count = site.map { blocker.hidden.selectors(on: $0).count } ?? 0
                Button(count > 0 ? "このサイトで隠した要素を元に戻す（\(count)件）" : "このサイトで隠した要素を元に戻す") {
                    guard let site, let tab = store.selected else { return }
                    Task {
                        await blocker.unhideAll(on: site)
                        tab.reload()
                    }
                }
                .disabled(count == 0)
                Divider()
                Text(blocker.filterSummary)
            }
        }
    }

    private var hasBookmarkForSelectedPage: Bool {
        store.selected.flatMap(store.bookmark(for:)) != nil
    }

    private func closeTab() {
        // ⌘W はこの項目が標準の「閉じる」より先に受けるので、設定の窓が手前にあればタブではなくその窓を閉じる。
        // シートやポップオーバー（親のある窓）が手前のときは、これまでどおりタブを閉じる。
        if let front = NSApp.orderedWindows.first(where: \.isVisible),
           front.identifier?.rawValue != HaneApp.windowID, front.parent == nil, front.sheetParent == nil {
            front.performClose(nil)
            return
        }
        if !store.closeSelected() {
            dismissWindow(id: HaneApp.windowID)
        }
    }
}

/// メニューのショートカットでは受けられないキーを、AppKit の局所モニタで先に拾う。WebView にフォーカスがあっても届く。
///
/// - ⌃1〜9: メニューの「プロファイル」で上から N 番目のプロファイルへ移る。プロファイルは起動したあとにも増え、
///   SwiftUI はメニューの中身を開く直前まで作り直さないので、増えた項目のショートカットはメニューを一度開くまで効かない。
/// - ⌃Tab / ⌃⇧Tab: 次・前のタブ。メニューの項目には ⇧⌘] / ⇧⌘[ を付けていて、一つの項目にキーは一つしか付かない。
///
/// 拾ったキーはページへ届かなくなるので、ページがよく使う組み合わせ（⌥⌘数字は Google ドキュメントや Notion の見出し）は取らない。
@MainActor
enum LocalShortcuts {
    static func install(model: BrowserModel) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handle(event, model: model) }
            // 当てはまらなければ、ページなど本来の受け手へそのまま流す。
            return handled ? nil : event
        }
    }

    private static let tabKeyCode: UInt16 = 48

    static func handle(_ event: NSEvent, model: BrowserModel) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == tabKeyCode, modifiers == .control || modifiers == [.control, .shift] {
            model.store.select(offset: modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        guard modifiers == .control,
              let number = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
              (1...9).contains(number), number <= model.names.count
        else { return false }
        // 押しっぱなしの繰り返しで何度も起こさない。
        if !event.isARepeat {
            model.open(model.names[number - 1])
        }
        return true
    }
}
