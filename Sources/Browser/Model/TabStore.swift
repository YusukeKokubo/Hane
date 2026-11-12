import Foundation
import Observation
import WebKit

/// 開いているタブの一覧と選択状態。今開いているプロファイルにつき一つで、窓は一つきり（`BrowserModel` が持つ）。
///
/// ページはふたつの置き場に分かれる。バーの右側に並ぶ普通のタブ（`tabs`）と、
/// ブックマークからその場で開いたページ（`bookmarkTabs`）。後者はブックマークに結びつき、
/// 閉じてもブックマークは残る。開いていないブックマークはタブを持たない。
///
/// しばらく画面に出していないタブは、選択が変わったときに眠らせてページのプロセスを返す（`sleepIdleTabs`）。
/// 眠らせるかを決めるのは選択が変わったときだけで、タイマーは使わない。
@MainActor
@Observable
final class TabStore: TabOpening {
    /// 普通のタブ。バーの右側に並ぶ。
    private(set) var tabs: [Tab] = []
    /// ページを開いているブックマーク。ブックマークのIDで引く。ブックマークとタブの結びつきはここだけで持つ。
    private(set) var bookmarkTabs: [UUID: Tab] = [:]
    var selectedID: Tab.ID? {
        // 前回の閲覧から戻したタブと眠らせたタブは、選ばれたここで起こす。
        didSet {
            guard selectedID != oldValue else { return }
            Signposts.poster.emitEvent("タブの選択")
            if let previous = oldValue.flatMap(tab(withID:)) { previous.lastShown = Date() }
            selected?.wake()
            sleepIdleTabs()
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
    /// 閲覧状態の書き出し。保存しないとき（テストなど）は `nil`。
    @ObservationIgnored private var recorder: SessionRecorder?
    @ObservationIgnored private var lastTabNumber = 0
    /// プロファイルを離れて閉じたか。閉じたあとに遅れて届く新しいタブの頼みや閲覧状態の書き出しを断る。
    @ObservationIgnored private(set) var isShutDown = false

    init(
        factory: PageFactory = PageFactory(),
        bookmarks: BookmarkStore = BookmarkStore(),
        history: HistoryStore = HistoryStore(),
        session: SessionStore = SessionStore()
    ) {
        self.factory = factory
        self.bookmarks = bookmarks
        self.history = history
        if !restore(session.load()) {
            newTab()
        }
        recorder = SessionRecorder(
            session: session,
            watched: { [weak self] in self?.touchSessionShape() },
            snapshot: { [weak self] in self?.sessionSnapshot() }
        )
    }

    /// バーに見える順のすべてのページ。ブックマークのページが先、普通のタブが後。
    var allTabs: [Tab] {
        bookmarks.allBookmarks.compactMap { bookmarkTabs[$0.id] } + tabs
    }

    var contentBlocker: ContentBlocker? { factory.contentBlocker }
    var downloads: Downloads { factory.downloads }

    var selected: Tab? {
        selectedID.flatMap(tab(withID:))
    }

    private func tab(withID id: Tab.ID) -> Tab? {
        tabs.first { $0.id == id } ?? bookmarkTabs.values.first { $0.id == id }
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
        // ページの判断は非同期なので、プロファイルを離れたあとに届くことがある。開くと閉じたはずのページが残る。
        guard !isShutDown else { return }
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

    /// ページが `window.close()` で自分を閉じた。最後の1枚でも窓は閉じず、空のタブを開く
    /// （ページの都合で窓ごと閉じてアプリを終わらせないため）。
    func closeTab(showing webView: WKWebView) {
        guard !isShutDown, let tab = allTabs.first(where: { $0.page?.webView === webView }) else { return }
        if !close(tab.id) { newTab() }
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
        bookmarkTabs[bookmark.id] = tab
        return bookmark
    }

    /// ブックマークかフォルダを消す。開いていたページは普通のタブとして残す。
    func removeBookmark(_ id: UUID) {
        if openFolder?.id == id { openFolder = nil }
        for removed in bookmarks.remove(id) {
            guard let tab = bookmarkTabs.removeValue(forKey: removed) else { continue }
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

    /// ブックマークから開いたページなら、そのブックマークのID。普通のタブなら `nil`。
    func bookmarkID(of tab: Tab) -> UUID? {
        bookmarkTabs.first { $0.value === tab }?.key
    }

    /// そのページに対応するブックマーク。ブックマークから開いたページか、同じアドレスのもの。
    func bookmark(for tab: Tab) -> Bookmark? {
        bookmarkID(of: tab).flatMap(bookmarks.bookmark) ?? bookmarks.bookmark(matching: tab.url)
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
            guard var page = tab.savedPage() else { continue }
            page.bookmark = bookmarkID(of: tab)
            if tab.id == selectedID { snapshot.selected = snapshot.pages.count }
            snapshot.pages.append(page)
        }
        return snapshot
    }

    /// 閲覧状態を書き出すきっかけにする値に触れる。並び・行き先・選択と、ページを移って最初に題名が届いたことだけで、
    /// 題名そのものには触れない。
    ///
    /// 未読の数などで題名を書き換え続けるページがあり、題名まで見張るとそのたびに全タブぶんの控えを取って書き出すことになる。
    /// 移ってから後の題名の変化は、次の書き出しか終了するときの書き出しに乗る。
    private func touchSessionShape() {
        _ = selectedID
        for tab in allTabs {
            _ = tab.url
            _ = tab.titleArrivals
        }
    }

    func saveSession() {
        guard !isShutDown else { return }
        recorder?.saveNow()
    }

    /// プロファイルを離れるときに呼ぶ。閲覧状態を書き出してから、すべてのページを閉じる。
    ///
    /// 閉じたあとは閲覧状態を書かない。同じプロファイルへすぐ戻ったとき、新しいタブ管理が書いた閲覧状態を
    /// 古い方が遅れて上書きしないため。
    func shutDown() {
        guard !isShutDown else { return }
        saveSession()
        isShutDown = true
        recorder = nil
        for tab in allTabs {
            tab.tearDown()
        }
        tabs = []
        bookmarkTabs = [:]
        openFolder = nil
        selectedID = nil
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

    // MARK: 眠らせる

    /// 画面から外れて `BrowserSettings.tabSleepDelay` より長く経ったタブを眠らせる。選択が変わったときに呼ぶ。
    ///
    /// 読み込み中のタブと、音や動画を流している・カメラやマイクを使っているタブは眠らせない。
    func sleepIdleTabs(now: Date = Date()) {
        let idle = allTabs.filter {
            $0.id != selectedID && $0.hasContent && !$0.isLoading
                && now.timeIntervalSince($0.lastShown) > BrowserSettings.tabSleepDelay
        }
        guard !idle.isEmpty else { return }
        Task {
            for tab in idle {
                guard let page = tab.page, !(await page.isBusy()) else { continue }
                // 確かめている間に選ばれたり、プロファイルを離れたりしていれば眠らせない。
                guard !isShutDown, tab.id != selectedID, tab.page === page else { continue }
                tab.sleep()
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
