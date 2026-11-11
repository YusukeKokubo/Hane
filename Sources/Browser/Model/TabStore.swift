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
    var selectedID: Tab.ID? {
        // 前回の閲覧から戻しただけのページは、選ばれたここで初めて読み込む。
        didSet {
            Signposts.poster.emitEvent("タブの選択")
            selected?.loadRestoredPage()
        }
    }

    let bookmarks: BookmarkStore
    let history: HistoryStore

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
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private var lastTabNumber = 0

    init(
        factory: PageFactory = PageFactory(),
        bookmarks: BookmarkStore = BookmarkStore(),
        history: HistoryStore = HistoryStore(),
        session: SessionStore = SessionStore()
    ) {
        self.factory = factory
        self.bookmarks = bookmarks
        self.history = history
        self.session = session
        if !restore(session.load()) {
            newTab()
        }
        if session.isPersistent {
            watchSession()
        }
    }

    /// バーに見える順のすべてのページ。ブックマークのページが先、普通のタブが後。
    var allTabs: [Tab] {
        bookmarks.allBookmarks.compactMap { bookmarkTabs[$0.id] } + tabs
    }

    var contentBlocker: ContentBlocker? { factory.contentBlocker }

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

    /// バーの左から N 番目（1始まり）の項目を使う。ブックマークは開き、フォルダは一覧を開け閉めし、タブは選ぶ。
    /// 9 は常に最後の普通のタブ。番号を見た目の並びと合わせるため、ブックマークとフォルダもタブと同じに数える。
    func activateBarItem(number: Int) {
        if number == 9 {
            if let last = tabs.last { selectedID = last.id }
            return
        }
        let items = bookmarks.items
        if items.indices.contains(number - 1) {
            switch items[number - 1] {
            case .bookmark(let bookmark): activate(bookmark: bookmark.id)
            case .folder(let folder): toggleFolder(folder.id)
            }
            return
        }
        let index = number - 1 - items.count
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
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), let url = tabs[index].url else { return nil }
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
        guard let url = bookmarkTabs[id]?.url else { return }
        bookmarks.setURL(id, to: url)
    }

    /// そのページに対応するブックマーク。ブックマークから開いたページか、同じアドレスのもの。
    func bookmark(for tab: Tab) -> Bookmark? {
        tab.bookmarkID.flatMap(bookmarks.bookmark) ?? bookmarks.bookmark(matching: tab.url)
    }

    /// ブックマークから開いたページがブックマークのアドレスから離れていれば、そのページ名を返す。
    func awayTitle(for bookmark: Bookmark) -> String? {
        guard let tab = bookmarkTabs[bookmark.id],
              let url = tab.url,
              !url.isSameDestination(as: bookmark.url)
        else { return nil }
        return tab.title
    }

    // MARK: フォルダの一覧

    /// バーで左から数えて N 番目のフォルダの一覧を開け閉めする。ブックマーク単体は数えない。
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
        /// 履歴から補って、選択された状態で入っている続き。
        var completion: String?
    }

    // MARK: 閲覧状態

    /// 今の閲覧状態。まっさらなタブは含めない。
    func sessionSnapshot() -> SavedSession {
        var snapshot = SavedSession()
        for tab in allTabs {
            guard let page = tab.savedPage else { continue }
            if tab.id == selectedID { snapshot.selected = snapshot.pages.count }
            snapshot.pages.append(page)
        }
        return snapshot
    }

    func saveSession() {
        session.save(sessionSnapshot())
    }

    /// 前回の閲覧状態からタブを並べ直す。戻せるページがひとつもなければ `false`。
    ///
    /// 読み込むのは選んでいたページだけで、ほかは選ばれるまで待たせる。
    private func restore(_ saved: SavedSession?) -> Bool {
        guard let saved else { return false }
        var selectedTab: Tab?
        for (index, page) in saved.pages.enumerated() {
            let tab = makeTab(restoring: page)
            if let id = page.bookmark, bookmarks.bookmark(id) != nil, bookmarkTabs[id] == nil {
                tab.bookmarkID = id
                bookmarkTabs[id] = tab
            } else {
                // ブックマークが見つからないページは、ブックマークを消したときと同じく普通のタブとして残す。
                tabs.append(tab)
            }
            if index == saved.selected { selectedTab = tab }
        }
        guard let fallback = selectedTab ?? tabs.last ?? allTabs.first else { return false }
        selectedID = fallback.id
        return true
    }

    /// 閲覧状態が変わるたびに書き出す。
    ///
    /// 変化を一度拾うと同じ処理の回の終わりまでまとめて待ち、書き出してから見張り直す。
    /// タイマーで定期的に書くのではなく、変化があったときだけ動く。
    private func watchSession() {
        withObservationTracking {
            _ = sessionSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.saveSession()
                self.watchSession()
            }
        }
    }

    private func makeTab(restoring saved: SavedPage? = nil) -> Tab {
        lastTabNumber += 1
        return Tab(number: lastTabNumber, factory: factory, opener: self, history: history, restoring: saved)
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
