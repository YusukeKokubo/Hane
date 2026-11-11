import Foundation
import Observation

/// 開いているタブの一覧と選択状態。ウインドウ1枚につき1つ。
///
/// ページはふたつの置き場に分かれる。バーの右側に並ぶ普通のタブ（`tabs`）と、
/// ブックマークからその場で開いたページ（`bookmarkTabs`）。後者はブックマークに結びつき、
/// 閉じてもブックマークは残る。開いていないブックマークは `WebPage` を持たない。
@MainActor
@Observable
final class TabStore: TabOpening {
    /// 普通のタブ。バーの右側に並ぶ。
    private(set) var tabs: [Tab] = []
    /// ページを開いているブックマーク。ブックマークのIDで引く。
    private(set) var bookmarkTabs: [UUID: Tab] = [:]
    var selectedID: Tab.ID?

    let bookmarks: BookmarkStore

    /// アドレスバーにフォーカスを移してほしいときに増やす合図。
    private(set) var addressFocusRequest = 0
    /// 選択中のページについて、ブックマークの追加・編集画面を開いてほしいときに増やす合図。
    private(set) var bookmarkEditorRequest = 0
    /// 一覧を下に出しているフォルダ。キーボードからも開け閉めするので、画面ではなくここで持つ。
    private(set) var openFolder: OpenFolder?

    /// アドレスバーの今の中身。外部から状態を尋ねられたときに答えるための写しで、
    /// 画面の更新には使わない。
    @ObservationIgnored var addressBar = AddressBarState()

    @ObservationIgnored private let factory: PageFactory
    @ObservationIgnored private var lastTabNumber = 0

    init(factory: PageFactory = PageFactory(), bookmarks: BookmarkStore = BookmarkStore()) {
        self.factory = factory
        self.bookmarks = bookmarks
        newTab()
    }

    /// バーに見える順のすべてのページ。ブックマークのページが先、普通のタブが後。
    var allTabs: [Tab] {
        bookmarks.allBookmarks.compactMap { bookmarkTabs[$0.id] } + tabs
    }

    var selected: Tab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID } ?? bookmarkTabs.values.first { $0.id == selectedID }
    }

    // MARK: タブの増減

    /// 空のタブを開いて選択し、アドレスバーにフォーカスを移す。
    @discardableResult
    func newTab() -> Tab {
        let tab = insertTab(after: nil)
        selectedID = tab.id
        focusAddressBar()
        return tab
    }

    func openTab(with request: URLRequest, inBackground: Bool) {
        open(request, inBackground: inBackground)
    }

    /// 選択中のタブの隣に、ページを読み込むタブを開く。
    @discardableResult
    func open(_ request: URLRequest, inBackground: Bool = false) -> Tab {
        let tab = insertTab(after: selectedID)
        tab.load(request)
        if !inBackground { selectedID = tab.id }
        return tab
    }

    /// ページを閉じる。何も残らなくなったら `false` を返す（呼び出し側でウインドウを閉じる）。
    ///
    /// ブックマークのページはページだけ閉じてブックマークを残す。
    /// それで何も残らなくても、ウインドウは閉じずに空のタブを開く。
    @discardableResult
    func close(_ id: Tab.ID) -> Bool {
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            let tab = tabs.remove(at: index)
            tab.tearDown()
            if selectedID == id {
                selectedID = tabs.indices.contains(index) ? tabs[index].id : (tabs.last ?? allTabs.first)?.id
            }
        } else if let entry = bookmarkTabs.first(where: { $0.value.id == id }) {
            bookmarkTabs[entry.key] = nil
            entry.value.tearDown()
            if allTabs.isEmpty {
                newTab()
            } else if selectedID == id {
                selectedID = (tabs.last ?? allTabs.first)?.id
            }
        }
        return !allTabs.isEmpty
    }

    @discardableResult
    func closeSelected() -> Bool {
        guard let selectedID else { return !allTabs.isEmpty }
        return close(selectedID)
    }

    // MARK: 選択の移動

    /// バーに見える順で前後へ移る。ブックマークのページも含める。
    func select(offset: Int) {
        let all = allTabs
        guard let current = all.firstIndex(where: { $0.id == selectedID }), !all.isEmpty else { return }
        let next = (current + offset + all.count) % all.count
        selectedID = all[next].id
    }

    /// 1始まりの番号で普通のタブを選ぶ。9は常に末尾のタブ。ブックマークは数えない。
    func select(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }

    func focusAddressBar() {
        addressFocusRequest += 1
    }

    func requestBookmarkEditor() {
        bookmarkEditorRequest += 1
    }

    // MARK: ブックマーク

    /// ブックマークを開く。ページがあればそこへ切り替え、なければその場で読み込む。
    @discardableResult
    func activate(bookmark id: UUID) -> Tab? {
        if let tab = bookmarkTabs[id] {
            selectedID = tab.id
            return tab
        }
        guard let bookmark = bookmarks.bookmark(id) else { return nil }
        let tab = makeTab()
        tab.bookmarkID = id
        tab.load(URLRequest(url: bookmark.url))
        bookmarkTabs[id] = tab
        selectedID = tab.id
        return tab
    }

    /// 普通のタブをブックマークにして、ページごとブックマークの側へ移す。
    @discardableResult
    func pin(_ tabID: Tab.ID, title: String? = nil, folder: UUID? = nil, before anchor: UUID? = nil) -> Bookmark? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), let url = tabs[index].page.url else { return nil }
        let tab = tabs.remove(at: index)
        let bookmark = bookmarks.add(title: title ?? tab.title, url: url, folder: folder, before: anchor)
        tab.bookmarkID = bookmark.id
        bookmarkTabs[bookmark.id] = tab
        return bookmark
    }

    /// ブックマークかフォルダを消す。開いていたページは普通のタブとして残す。
    func removeBookmark(_ id: UUID) {
        if openFolder?.id == id { openFolder = nil }
        for removed in bookmarks.remove(id) {
            guard let tab = bookmarkTabs.removeValue(forKey: removed) else { continue }
            tab.bookmarkID = nil
            tabs.append(tab)
        }
    }

    /// バーへのドロップを、ブックマークの移動か、タブのブックマーク化に置き換える。
    func drop(_ item: BarDragItem, into folder: UUID?, before anchor: UUID?) {
        switch item {
        case .tab(let id):
            pin(id, folder: folder, before: anchor)
        case .bookmark(let id) where bookmarks.folder(id) != nil:
            // フォルダはフォルダに入れられないので、落とされた場所の前に置く。
            bookmarks.move(id, into: nil, before: anchor ?? folder)
        case .bookmark(let id):
            bookmarks.move(id, into: folder, before: anchor)
        }
    }

    /// ブックマークから開いたページを、ブックマークのアドレスへ戻す。
    func returnToBookmark(_ id: UUID) {
        guard let bookmark = bookmarks.bookmark(id), let tab = bookmarkTabs[id] else { return }
        tab.load(URLRequest(url: bookmark.url))
    }

    /// ブックマークの行き先を、そこから開いているページの今のアドレスに付け替える。
    func updateBookmarkToCurrentPage(_ id: UUID) {
        guard let url = bookmarkTabs[id]?.page.url else { return }
        bookmarks.setURL(id, to: url)
    }

    /// そのページに対応するブックマーク。ブックマークから開いたページか、同じアドレスのもの。
    func bookmark(for tab: Tab) -> Bookmark? {
        tab.bookmarkID.flatMap(bookmarks.bookmark) ?? bookmarks.bookmark(matching: tab.page.url)
    }

    /// ブックマークから開いたページがブックマークのアドレスから離れていれば、そのページ名を返す。
    func awayTitle(for bookmark: Bookmark) -> String? {
        guard let tab = bookmarkTabs[bookmark.id],
              let url = tab.page.url,
              !url.isSameDestination(as: bookmark.url)
        else { return nil }
        return tab.title
    }

    // MARK: フォルダの一覧

    /// バーで左から数えて N 番目のフォルダの一覧を開け閉めする。ブックマーク単体は数えない。
    func toggleFolder(number: Int) {
        let folders = bookmarks.folders
        guard folders.indices.contains(number - 1) else { return }
        toggleFolder(folders[number - 1].id)
    }

    func toggleFolder(_ id: UUID) {
        if openFolder?.id == id {
            openFolder = nil
            return
        }
        guard let folder = bookmarks.folder(id) else { return }
        // 中のページを見ているなら、その行から選び始める。
        let current = folder.bookmarks.firstIndex { bookmarkTabs[$0.id]?.id == selectedID }
        openFolder = OpenFolder(id: id, highlighted: current ?? 0)
    }

    /// 一覧を閉じる。別のフォルダへ切り替えた直後に古い一覧の閉じる知らせが来ても、新しい方は閉じない。
    func closeFolder(_ id: UUID? = nil) {
        guard openFolder != nil, id == nil || openFolder?.id == id else { return }
        openFolder = nil
    }

    /// 選択の当たっている行を動かす。端で止める。
    func moveFolderHighlight(by offset: Int) {
        guard let open = openFolder, let count = bookmarks.folder(open.id)?.bookmarks.count, count > 0 else { return }
        openFolder?.highlighted = min(max(open.highlighted + offset, 0), count - 1)
    }

    func highlightFolderRow(_ index: Int) {
        openFolder?.highlighted = index
    }

    /// 一覧の行（省けば選択の当たっている行）のブックマークを開いて、一覧を閉じる。
    @discardableResult
    func activateFolderRow(_ index: Int? = nil) -> Tab? {
        guard let open = openFolder, let rows = bookmarks.folder(open.id)?.bookmarks else { return nil }
        let row = index ?? open.highlighted
        guard rows.indices.contains(row) else { return nil }
        openFolder = nil
        return activate(bookmark: rows[row].id)
    }

    struct OpenFolder: Equatable {
        let id: UUID
        /// キーボードの選択が当たっている行。0始まり。
        var highlighted: Int
    }

    struct AddressBarState {
        var text = ""
        var isFocused = false
    }

    private func makeTab() -> Tab {
        lastTabNumber += 1
        return Tab(number: lastTabNumber, factory: factory, opener: self)
    }

    private func insertTab(after anchor: Tab.ID?) -> Tab {
        let tab = makeTab()
        if let anchor, let index = tabs.firstIndex(where: { $0.id == anchor }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        return tab
    }
}
