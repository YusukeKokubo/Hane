import AppKit
import Observation

/// 開いているタブの一覧と選択状態。今開いているプロファイルにつき一つで、窓は一つきり（`BrowserModel` が持つ）。
///
/// ページはふたつの置き場に分かれる。バーの右側に並ぶ普通のタブ（`tabs`）と、
/// ブックマークからその場で開いたページ（`bookmarkTabs`）。後者はブックマークに結びつき、
/// 閉じてもブックマークは残る。開いていないブックマークはタブを持たない。
///
/// 普通のタブは組（`TabGroup`）に分けて持ち、バーには選んでいる組のタブ（`tabs`）だけを出す。
/// ほかの組のタブ（`parkedTabs`）は、選ばれていないタブと同じ扱いで、眠らせ方も変わらない。
/// ブックマークには、どの組を出していてもバーの左に並ぶものと、組ごとの固定（`Bookmark.group`）がある。
/// 組の固定はその組を出しているときだけ、組の切り替えの右に並ぶ。どちらのページも `bookmarkTabs` で持つ。
///
/// しばらく画面に出していないタブは、選択が変わったときに眠らせてページのプロセスを返す（`sleepIdleTabs`）。
/// 眠らせるかを決めるのは選択が変わったときだけで、タイマーは使わない。
@MainActor
@Observable
final class TabStore: TabOpening {
    /// 今出している組の普通のタブ。バーの右側に並ぶ。
    private(set) var tabs: [Tab] = []
    /// 普通のタブの組。並びはバーと一覧に出す順。
    private(set) var groups: [TabGroup] = []
    /// 今バーに出している組。`nil` はどの組にも入っていないタブ。
    private(set) var currentGroupID: UUID?
    /// 出していない組の普通のタブ。組のIDで引き、`nil` はどの組にも入っていないタブ。空になった組は持たない。
    private(set) var parkedTabs: [UUID?: [Tab]] = [:]
    /// 組の名前を打ってもらう頼み。画面が入力欄を出して受け、`finishGroupNaming` で返す。
    private(set) var groupNaming: GroupNaming?
    /// ページを開いているブックマーク。ブックマークのIDで引く。ブックマークとタブの結びつきはここだけで持つ。
    private(set) var bookmarkTabs: [UUID: Tab] = [:]
    var selectedID: Tab.ID? {
        // 前回の閲覧から戻したタブと眠らせたタブは、選ばれたここで起こす。
        didSet {
            guard selectedID != oldValue else { return }
            // ほかのタブへ移ったら、開いたタブを閉じても元へは戻さない（どこへ戻るかが読めなくなるため）。
            if returnOnClose?.tab != selectedID { returnOnClose = nil }
            Signposts.poster.emitEvent("タブの選択")
            if let previous = oldValue.flatMap(tab(withID:)) { previous.lastShown = Date() }
            selected?.wake()
            sleepIdleTabs()
            // 移った先のページでそのままキーを使えるように。まっさらなタブでは、続けてアドレスバーへ移す（`newTab`）。
            pageFocusRequest += 1
        }
    }

    let bookmarks: BookmarkStore
    let history: HistoryStore
    let favicons: FaviconStore
    /// 1Password のログインを選んでいるページに入れる（⌘\）。
    let passwordFill: PasswordFill

    /// アドレスバーにフォーカスを移してほしいときに増やす合図。
    private(set) var addressFocusRequest = 0
    /// 選択中のページへキーボードのフォーカスを移してほしいときに増やす合図。
    /// アドレスバーで開いたあとやタブを移ったあと、クリックしなくてもページでキーを使えるようにするため。
    private(set) var pageFocusRequest = 0
    /// 選択中のページについて、ブックマークの追加・編集画面を開いてほしいときに増やす合図。
    private(set) var bookmarkEditorRequest = 0
    /// 閉じたページの控え。新しく閉じたものが後ろ。⇧⌘T で後ろから開き直す。
    /// 控えには戻る・進むの履歴も入るので、数を `BrowserSettings.closedTabLimit` で区切る。ファイルには残さない。
    private(set) var closedTabs: [ClosedTab] = []

    /// この窓がキーを受ける窓か。閲覧履歴で、ページを見ていた時間を数えるのに使う。
    var isWindowKey = false

    /// アドレスバーの今の中身。外部から状態を尋ねられたときに答えるための写しで、
    /// 画面の更新には使わない。
    @ObservationIgnored var addressBar = AddressBarState()

    @ObservationIgnored private let factory: PageFactory
    /// 閲覧状態の書き出し。保存しないとき（テストなど）は `nil`。
    @ObservationIgnored private var recorder: SessionRecorder?
    /// 見ているページを閲覧履歴へ伝える。
    @ObservationIgnored private var viewingRecorder: ViewingRecorder?
    @ObservationIgnored private var lastTabNumber = 0
    /// 組ごとに最後に選んでいたページ。組へ戻ったときにそこを選ぶ。
    @ObservationIgnored private var groupSelections: [UUID?: Tab.ID] = [:]
    /// プロファイルを離れて閉じたか。閉じたあとに遅れて届く新しいタブの頼みや閲覧状態の書き出しを断る。
    @ObservationIgnored private(set) var isShutDown = false

    init(
        factory: PageFactory = PageFactory(),
        bookmarks: BookmarkStore = BookmarkStore(),
        history: HistoryStore = HistoryStore(),
        favicons: FaviconStore = FaviconStore(),
        session: SessionStore = SessionStore(),
        loginFields: LoginFieldStore = LoginFieldStore()
    ) {
        self.factory = factory
        passwordFill = PasswordFill(places: loginFields)
        self.bookmarks = bookmarks
        self.history = history
        self.favicons = favicons
        if !restore(session.load()) {
            newTab()
        }
        // 閲覧状態から消えた組の固定は、組を解いたときと同じく組に入っていないタブの固定にする。
        // 拾わないと、どの組を出しても見えないまま残る。
        let known = Set(groups.map(\.id))
        bookmarks.ungroupPins { !known.contains($0) }
        recorder = SessionRecorder(
            session: session,
            watched: { [weak self] in self?.touchSessionShape() },
            snapshot: { [weak self] in self?.sessionSnapshot() }
        )
        viewingRecorder = ViewingRecorder(history: history) { [weak self] in
            guard let self, self.isWindowKey, ViewerPresence.shared.isPresent else { return nil }
            return self.selected?.page?.url
        }
    }

    /// バーに見える順のすべてのページ。ブックマーク、組の固定、普通のタブの順。
    var allTabs: [Tab] {
        barBookmarks.compactMap { bookmarkTabs[$0.id] } + tabs
    }

    /// どの組を出していても並ぶブックマーク。
    var sharedBookmarks: [Bookmark] {
        bookmarks.bookmarks(in: nil)
    }

    /// 出している組の固定。
    var groupBookmarks: [Bookmark] {
        bookmarks.bookmarks(in: PinnedGroup(id: currentGroupID))
    }

    /// バーに見える順のブックマーク。どの組でも並ぶものが先、出している組の固定が後。
    var barBookmarks: [Bookmark] {
        sharedBookmarks + groupBookmarks
    }

    /// すべてのブックマークを、どの組でも並ぶもの、組に入っていないタブの固定、組の並び順の固定の順に。
    var listedBookmarks: [Bookmark] {
        sharedBookmarks + groupKeys.flatMap { bookmarks.bookmarks(in: PinnedGroup(id: $0)) }
    }

    /// 出していない組のタブも含めた、すべてのページ。ブックマークのページ、組に入っていないタブ、組の並び順。
    var everyTab: [Tab] {
        bookmarks.bookmarks.compactMap { bookmarkTabs[$0.id] } + groupKeys.flatMap(tabs(in:))
    }

    /// 組に入っていないタブ（`nil`）と、組の並び。
    private var groupKeys: [UUID?] {
        [nil] + groups.map(\.id)
    }

    /// その組の普通のタブ。`nil` は組に入っていないタブ。
    func tabs(in group: UUID?) -> [Tab] {
        group == currentGroupID ? tabs : parkedTabs[group] ?? []
    }

    var currentGroup: TabGroup? {
        currentGroupID.flatMap(group(withID:))
    }

    func group(withID id: UUID) -> TabGroup? {
        groups.first { $0.id == id }
    }

    func group(named name: String) -> TabGroup? {
        groups.first { $0.name == name }
    }

    /// 普通のタブなら、入っている組（組に入っていなければ `.some(nil)`）。ブックマークのページなどは `nil`。
    func groupKey(of tabID: Tab.ID) -> UUID?? {
        groupKeys.first { tabs(in: $0).contains { $0.id == tabID } }
    }

    var contentBlocker: ContentBlocker? { factory.contentBlocker }
    var downloads: Downloads { factory.downloads }

    var selected: Tab? {
        selectedID.flatMap(tab(withID:))
    }

    private func tab(withID id: Tab.ID) -> Tab? {
        tabs.first { $0.id == id } ?? bookmarkTabs.values.first { $0.id == id }
            ?? parkedTabs.values.lazy.flatMap(\.self).first { $0.id == id }
    }

    // MARK: タブの増減

    /// 空のタブを開いて選択し、アドレスバーにフォーカスを移す。
    @discardableResult
    func newTab() -> Tab {
        let tab = insertTab(after: nil)
        select(opened: tab)
        focusAddressBar()
        return tab
    }

    func openTab(with request: URLRequest, inBackground: Bool) {
        // ページの判断は非同期なので、プロファイルを離れたあとに届くことがある。開くと閉じたはずのページが残る。
        guard !isShutDown else { return }
        open(request, inBackground: inBackground, from: .link)
    }

    /// 選択中のタブの隣に、ページを読み込むタブを開く。`source` は履歴でどこから来たと数えるか。
    @discardableResult
    func open(_ request: URLRequest, inBackground: Bool = false, from source: VisitSource? = nil) -> Tab {
        let tab = insertTab(after: selectedID)
        tab.load(request, from: source)
        if !inBackground { select(opened: tab) }
        return tab
    }

    /// 開いたばかりのタブを選ぶ。ほかへ移らずに閉じたら、それまで選んでいたタブへ戻す。
    /// 隣へ移すと、開いたついでに見ただけのタブを閉じたとき、元いたタブを探し直すことになるため。
    private func select(opened tab: Tab) {
        let back = selectedID
        selectedID = tab.id
        returnOnClose = back.map { (tab: tab.id, back: $0) }
    }

    /// 開いて選んだタブと、そのとき選んでいたタブ。
    @ObservationIgnored private var returnOnClose: (tab: Tab.ID, back: Tab.ID)?

    /// 選ばれていたタブ `id` を閉じたあとに選ぶタブ。開いたときに選んでいたタブが見えていればそこ。
    private func returnTarget(closing id: Tab.ID) -> Tab.ID? {
        guard let entry = returnOnClose, entry.tab == id else { return nil }
        return allTabs.first { $0.id == entry.back }?.id
    }

    /// ページを閉じる。何も残らなくなったら `false` を返す（呼び出し側でウインドウを閉じる）。
    ///
    /// ブックマークのページはページだけ閉じてブックマークを残す。
    /// それで何も残らなくても、ウインドウは閉じずに空のタブを開く。ほかの組にタブが残っているときも同じ。
    @discardableResult
    func close(_ id: Tab.ID) -> Bool {
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            let tab = tabs.remove(at: index)
            remember(tab, at: index, group: currentGroupID)
            tab.tearDown()
            if allTabs.isEmpty, !parkedTabs.isEmpty {
                newTab()
            } else if selectedID == id {
                selectedID = returnTarget(closing: id)
                    ?? (tabs.indices.contains(index) ? tabs[index].id : (tabs.last ?? allTabs.first)?.id)
            }
        } else if let entry = parkedTabs.first(where: { $0.value.contains { $0.id == id } }),
                  let index = entry.value.firstIndex(where: { $0.id == id }) {
            // 出していない組のページが自分を閉じた（`window.close()`）。
            // 組に入っていないタブの鍵は `nil` なので、`if let` で鍵だけを取り出さない（見つからないのと見分けがつかない）。
            let key = entry.key
            let tab = parkedTabs[key]!.remove(at: index)
            if parkedTabs[key]!.isEmpty { parkedTabs[key] = nil }
            remember(tab, at: index, group: key)
            tab.tearDown()
        } else if let entry = bookmarkTabs.first(where: { $0.value.id == id }) {
            bookmarkTabs[entry.key] = nil
            remember(entry.value, bookmark: entry.key)
            entry.value.tearDown()
            if allTabs.isEmpty {
                newTab()
            } else if selectedID == id {
                selectedID = returnTarget(closing: id) ?? (tabs.last ?? allTabs.first)?.id
            }
        }
        return !allTabs.isEmpty
    }

    /// ページが `window.close()` で自分を閉じた。最後の1枚でも窓は閉じず、空のタブを開く
    /// （ページの都合で窓ごと閉じてアプリを終わらせないため）。
    func closeTab(_ tab: Tab) {
        guard !isShutDown, everyTab.contains(where: { $0 === tab }) else { return }
        if !close(tab.id) { newTab() }
    }

    func perform(_ command: KeyCommand, from tab: Tab) {
        guard !isShutDown, everyTab.contains(where: { $0 === tab }) else { return }
        switch command {
        case .back: tab.goBack()
        case .forward: tab.goForward()
        case .reload: tab.reload()
        case .nextTab: select(offset: 1)
        case .previousTab: select(offset: -1)
        // ⌘W と違い、最後の1枚でも窓は閉じない。ページの中の一打で窓ごと消えないように。
        case .closeTab: closeTab(tab)
        case .reopenClosedTab: reopenClosedTab()
        case .focusAddressBar: focusAddressBar()
        case .copyURL:
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        case .openInNewTab(let url): open(URLRequest(url: url), inBackground: true)
        }
    }

    /// 最後に閉じたページを開き直して選ぶ。戻る・進むの履歴も戻す。開き直すものがなければ `nil`。
    ///
    /// 普通のタブは閉じたときの組と位置へ戻す（組が残っていて今出していなければ、その組へ移る）。
    /// ブックマークのページは、ブックマークが残っていてページを開いていなければ
    /// ブックマークの側へ戻し、そうでなければ普通のタブとして選択中のタブの隣に開く。
    @discardableResult
    func reopenClosedTab() -> Tab? {
        guard !isShutDown, let closed = closedTabs.popLast() else { return nil }
        let tab = makeTab(restoring: closed.page)
        if let id = closed.page.bookmark, let bookmark = bookmarks.bookmark(id), bookmarkTabs[id] == nil {
            showGroup(holding: bookmark)
            bookmarkTabs[id] = tab
        } else if let index = closed.index {
            if closed.group != currentGroupID, closed.group.map({ group(withID: $0) != nil }) ?? true {
                swapShownGroup(to: closed.group)
            }
            tabs.insert(tab, at: min(index, tabs.count))
        } else if let anchor = selectedID, let index = tabs.firstIndex(where: { $0.id == anchor }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        // 選んだところで控えから起こす（`selectedID` の didSet）。
        selectedID = tab.id
        return tab
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

    /// バーの左から N 番目（1始まり）の項目を使う。ブックマークは開き、タブは選ぶ。
    /// 9 は常に最後の普通のタブ。番号を見た目の並びと合わせるため、ブックマークもタブと同じに数える。
    func activateBarItem(number: Int) {
        if number == 9 {
            if let last = tabs.last { selectedID = last.id }
            return
        }
        let pinned = barBookmarks
        if pinned.indices.contains(number - 1) {
            activate(bookmark: pinned[number - 1].id)
            return
        }
        let index = number - 1 - pinned.count
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }

    func focusAddressBar() {
        addressFocusRequest += 1
    }

    func focusPage() {
        pageFocusRequest += 1
    }

    func requestBookmarkEditor() {
        bookmarkEditorRequest += 1
    }

    // MARK: ブックマーク

    /// ブックマークを開く。ページがあればそこへ切り替え、なければその場で読み込む。
    /// ほかの組の固定なら、その組を出してから開く。
    @discardableResult
    func activate(bookmark id: UUID) -> Tab? {
        guard let bookmark = bookmarks.bookmark(id) else { return nil }
        showGroup(holding: bookmark)
        if let tab = bookmarkTabs[id] {
            selectedID = tab.id
            return tab
        }
        let tab = makeTab()
        tab.load(URLRequest(url: bookmark.url), from: .bookmark)
        bookmarkTabs[id] = tab
        selectedID = tab.id
        return tab
    }

    /// 出している組の普通のタブをブックマークにして、ページごとブックマークの側へ移す。
    /// `group` を渡せば組の固定になる。ページが見えなくならないよう、固定できるのは出している組だけ。
    @discardableResult
    func pin(_ tabID: Tab.ID, title: String? = nil, to group: PinnedGroup? = nil, before anchor: UUID? = nil) -> Bookmark? {
        guard group.map({ $0.id == currentGroupID }) ?? true,
              let index = tabs.firstIndex(where: { $0.id == tabID }), let url = tabs[index].url
        else { return nil }
        let tab = tabs.remove(at: index)
        let bookmark = bookmarks.add(title: title ?? tab.title, url: url, group: group, before: anchor)
        bookmarkTabs[bookmark.id] = tab
        return bookmark
    }

    /// 出している組の固定にする（`pin` の組を出している組に決めたもの）。
    @discardableResult
    func pinToGroup(_ tabID: Tab.ID, before anchor: UUID? = nil) -> Bookmark? {
        pin(tabID, to: PinnedGroup(id: currentGroupID), before: anchor)
    }

    /// ブックマークを消す。開いていたページは普通のタブとして残す。組の固定ならその組へ、
    /// どの組でも並ぶものなら出している組へ入れ、`anchor` のタブの前（省くと末尾）に置く。
    /// `opening` なら、ページを開いていなくても普通のタブとして裏で開く（タブの並びへドラッグしたとき）。
    func removeBookmark(_ id: UUID, before anchor: Tab.ID? = nil, opening: Bool = false) {
        guard let bookmark = bookmarks.bookmark(id), bookmarks.remove(id) else { return }
        var tab = bookmarkTabs.removeValue(forKey: id)
        if tab == nil, opening {
            let opened = makeTab()
            opened.load(URLRequest(url: bookmark.url), from: .bookmark)
            tab = opened
        }
        guard let tab else { return }
        let group = bookmark.group?.id ?? currentGroupID
        if group == currentGroupID {
            let position = anchor.flatMap { anchor in tabs.firstIndex { $0.id == anchor } }
            tabs.insert(tab, at: position ?? tabs.endIndex)
        } else {
            parkedTabs[group, default: []].append(tab)
        }
    }

    /// ブックマークの置き場と並びを変える（`nil` はどの組でも並ぶもの）。`anchor` は移す先の置き場のもの。
    /// 開いているページを選んでいて、ほかの組の固定へ移したなら、見えなくなるので選び直す。
    func moveBookmark(_ id: UUID, to place: PinnedGroup?, before anchor: UUID? = nil) {
        guard place?.id.map({ group(withID: $0) != nil }) ?? true else { return }
        bookmarks.move(id, to: place, before: anchor)
        guard let tab = bookmarkTabs[id], tab.id == selectedID, !allTabs.contains(where: { $0 === tab }) else { return }
        if let next = tabs.last ?? allTabs.first {
            selectedID = next.id
        } else {
            newTab()
        }
    }

    /// ブックマークの並び（`place` が `nil` ならどの組でも並ぶもの、そうでなければ組の固定）へのドロップを、
    /// ブックマークの移動か、タブの固定に置き換える。
    func drop(_ item: BarDragItem, pinningTo place: PinnedGroup?, before anchor: UUID?) {
        switch item {
        case .tab(let id): pin(id, to: place, before: anchor)
        case .bookmark(let id): moveBookmark(id, to: place, before: anchor)
        case .group: break
        }
    }

    /// 普通のタブの並びへのドロップを、タブの並べ替えか、固定を外すことに置き換える。
    func dropOnTabs(_ item: BarDragItem, before anchor: Tab.ID?) {
        switch item {
        case .tab(let id): moveTab(id, before: anchor)
        case .bookmark(let id): removeBookmark(id, before: anchor, opening: true)
        case .group: break
        }
    }

    /// 出している組の普通のタブの並びを変える。`anchor` のタブの前へ、省くと末尾へ。
    func moveTab(_ id: Tab.ID, before anchor: Tab.ID? = nil) {
        guard id != anchor, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var reordered = tabs
        let tab = reordered.remove(at: index)
        let position = anchor.flatMap { anchor in reordered.firstIndex { $0.id == anchor } }
        reordered.insert(tab, at: position ?? reordered.endIndex)
        tabs = reordered
    }

    /// ほかの組の固定なら、その組を出す。選択は呼んだ側が変える。
    private func showGroup(holding bookmark: Bookmark) {
        guard let place = bookmark.group, place.id != currentGroupID,
              place.id.map({ group(withID: $0) != nil }) ?? true
        else { return }
        swapShownGroup(to: place.id)
    }

    /// ブックマークから開いたページを、ブックマークのアドレスへ戻す。
    func returnToBookmark(_ id: UUID) {
        guard let bookmark = bookmarks.bookmark(id), let tab = bookmarkTabs[id] else { return }
        tab.load(URLRequest(url: bookmark.url), from: .bookmark)
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

    struct ClosedTab {
        /// ブックマークのページなら、控えの `bookmark` にそのブックマークが入る。
        let page: SavedPage
        /// 普通のタブだったときの、組の中の位置。
        let index: Int?
        /// 普通のタブだったときに入っていた組。
        var group: UUID?
    }

    struct AddressBarState {
        var text = ""
        var isFocused = false
        /// 履歴から補って、選択された状態で入っている続き。
        var completion: String?
    }

    // MARK: 組

    /// 組を出す（`nil` は組に入っていないタブ）。前にその組で選んでいたページを選び、タブが一枚もなければ空のタブを開く。
    func showGroup(_ id: UUID?) {
        guard !isShutDown, id != currentGroupID, id.map({ group(withID: $0) != nil }) ?? true else { return }
        swapShownGroup(to: id)
        let remembered = groupSelections[id].flatMap { id in allTabs.first { $0.id == id } }
        let pinned = groupBookmarks.compactMap { bookmarkTabs[$0.id] }.last
        if let next = remembered ?? tabs.last ?? pinned {
            selectedID = next.id
        } else {
            newTab()
        }
    }

    /// 新しい組を作って出す。タブを渡せば、そのタブを連れて移る。名前が空なら作らない。
    @discardableResult
    func createGroup(named name: String, moving tabID: Tab.ID? = nil) -> TabGroup? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isShutDown, !name.isEmpty else { return nil }
        let group = TabGroup(id: UUID(), name: name, showsInBar: false)
        groups.append(group)
        if let tabID, groupKey(of: tabID) != nil {
            move(tabID, to: group.id, following: true)
        } else {
            showGroup(group.id)
        }
        return group
    }

    /// 普通のタブをほかの組へ移す（`nil` は組から外す）。`following` なら移った先の組を出してそのタブを選ぶ。
    ///
    /// 出している組から選んでいるタブを移して、ついて行かないときは、閉じたときと同じく隣を選ぶ。
    func move(_ tabID: Tab.ID, to target: UUID?, following: Bool = false) {
        guard !isShutDown, let source = groupKey(of: tabID), source != target,
              target.map({ group(withID: $0) != nil }) ?? true
        else { return }
        let tab: Tab
        var index: Int?
        if source == currentGroupID {
            index = tabs.firstIndex { $0.id == tabID }
            tab = tabs.remove(at: index!)
        } else {
            let at = parkedTabs[source]!.firstIndex { $0.id == tabID }!
            tab = parkedTabs[source]!.remove(at: at)
            if parkedTabs[source]!.isEmpty { parkedTabs[source] = nil }
        }
        if target == currentGroupID {
            tabs.append(tab)
        } else {
            parkedTabs[target, default: []].append(tab)
        }
        if following {
            if target != currentGroupID { swapShownGroup(to: target) }
            selectedID = tab.id
        } else if selectedID == tabID, let index {
            let next: Tab? = tabs.indices.contains(index) ? tabs[index] : (tabs.last ?? allTabs.first)
            if let next {
                selectedID = next.id
            } else {
                newTab()
            }
        }
    }

    func renameGroup(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
    }

    /// 組の並びを変える。`anchor` の組の前へ、省くと末尾へ。バーに並べた名前もこの順に出る。
    func moveGroup(_ id: UUID, before anchor: UUID? = nil) {
        guard id != anchor, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        var reordered = groups
        let group = reordered.remove(at: index)
        let position = anchor.flatMap { anchor in reordered.firstIndex { $0.id == anchor } }
        reordered.insert(group, at: position ?? reordered.endIndex)
        groups = reordered
    }

    func setShowsInBar(_ id: UUID, _ shows: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].showsInBar = shows
    }

    /// 組を解く。中のタブは閉じずに、組に入っていないタブの後ろへ移す。組の固定も、組に入っていないタブの固定にする。
    /// 出している組なら、組に入っていないタブを出す。
    func removeGroup(_ id: UUID) {
        guard !isShutDown, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        bookmarks.ungroupPins { $0 == id }
        if currentGroupID == id {
            tabs = (parkedTabs.removeValue(forKey: nil) ?? []) + tabs
            groupSelections[nil] = nil
            currentGroupID = nil
        } else if let moved = parkedTabs.removeValue(forKey: id) {
            if currentGroupID == nil {
                tabs += moved
            } else {
                parkedTabs[nil, default: []] += moved
            }
        }
        groups.remove(at: index)
        groupSelections[id] = nil
    }

    func requestGroupName(_ naming: GroupNaming) {
        guard !isShutDown else { return }
        groupNaming = naming
    }

    /// 名前の入力を終えた。`nil` は取りやめ。
    func finishGroupNaming(_ name: String?) {
        guard let naming = groupNaming else { return }
        groupNaming = nil
        guard let name else { return }
        switch naming {
        case .create(let tabID): createGroup(named: name, moving: tabID)
        case .rename(let id): renameGroup(id, to: name)
        }
    }

    /// バーに出す組を入れ替える。選択は変えないので、呼んだ側が選び直す。
    private func swapShownGroup(to id: UUID?) {
        groupSelections[currentGroupID] = selectedID
        parkedTabs[currentGroupID] = tabs.isEmpty ? nil : tabs
        tabs = parkedTabs.removeValue(forKey: id) ?? []
        currentGroupID = id
    }

    // MARK: 閲覧状態

    /// 今の閲覧状態。まっさらなタブは含めない。
    func sessionSnapshot() -> SavedSession {
        var snapshot = SavedSession()
        func add(_ tab: Tab, bookmark: UUID? = nil, group: UUID? = nil) {
            guard var page = tab.savedPage() else { return }
            page.bookmark = bookmark
            page.group = group
            if tab.id == selectedID { snapshot.selected = snapshot.pages.count }
            snapshot.pages.append(page)
        }
        for bookmark in bookmarks.bookmarks {
            if let tab = bookmarkTabs[bookmark.id] { add(tab, bookmark: bookmark.id) }
        }
        for key in groupKeys {
            for tab in tabs(in: key) { add(tab, group: key) }
        }
        if !groups.isEmpty {
            snapshot.groups = groups
            snapshot.currentGroup = currentGroupID
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
        _ = groups
        _ = currentGroupID
        for tab in everyTab {
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
        viewingRecorder?.stop()
        viewingRecorder = nil
        for tab in everyTab {
            tab.tearDown()
        }
        tabs = []
        parkedTabs = [:]
        bookmarkTabs = [:]
        groupNaming = nil
        closedTabs = []
        selectedID = nil
    }

    /// 前回の閲覧状態からタブを並べ直す。戻せるページがひとつもなければ `false`。
    ///
    /// 読み込むのは選んでいたページだけで、ほかは選ばれるまで待たせる。
    private func restore(_ saved: SavedSession?) -> Bool {
        guard let saved else { return false }
        groups = saved.groups ?? []
        let known = Set(groups.map(\.id))
        currentGroupID = saved.currentGroup.flatMap { known.contains($0) ? $0 : nil }
        var selectedTab: Tab?
        for (index, page) in saved.pages.enumerated() {
            let tab = makeTab(restoring: page)
            if let id = page.bookmark, bookmarks.bookmark(id) != nil, bookmarkTabs[id] == nil {
                bookmarkTabs[id] = tab
            } else {
                // ブックマークが見つからないページは、ブックマークを消したときと同じく普通のタブとして残す。
                // 組が見つからないページは、組に入っていないタブにする。
                let group = page.group.flatMap { known.contains($0) ? $0 : nil }
                if group == currentGroupID {
                    tabs.append(tab)
                } else {
                    parkedTabs[group, default: []].append(tab)
                }
            }
            if index == saved.selected { selectedTab = tab }
        }
        // 選んでいたページは出している組にあるはずだが、ファイルが食い違っていても見えないタブは選ばない。
        let shown = selectedTab.flatMap { tab in allTabs.contains { $0 === tab } ? tab : nil }
        guard let fallback = shown ?? tabs.last ?? allTabs.first else { return false }
        selectedID = fallback.id
        return true
    }

    // MARK: 眠らせる

    /// 画面から外れて `BrowserSettings.tabSleepDelay` より長く経ったタブを眠らせる。選択が変わったときに呼ぶ。
    ///
    /// 読み込み中のタブと、音や動画を流している・カメラやマイクを使っているタブは眠らせない。
    func sleepIdleTabs(now: Date = Date()) {
        let idle = everyTab.filter {
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

    /// 閉じるページの控えを取っておく。行き先のないまっさらなタブは残さない。
    private func remember(_ tab: Tab, at index: Int? = nil, bookmark: UUID? = nil, group: UUID? = nil) {
        guard var page = tab.savedPage() else { return }
        page.bookmark = bookmark
        closedTabs.append(ClosedTab(page: page, index: index, group: group))
        if closedTabs.count > BrowserSettings.closedTabLimit {
            closedTabs.removeFirst(closedTabs.count - BrowserSettings.closedTabLimit)
        }
    }

    private func makeTab(restoring saved: SavedPage? = nil) -> Tab {
        lastTabNumber += 1
        return Tab(number: lastTabNumber, factory: factory, opener: self, history: history, favicons: favicons, restoring: saved)
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
