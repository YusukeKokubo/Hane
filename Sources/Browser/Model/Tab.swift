import Foundation
import Observation
import os

/// タブ1枚ぶんの状態。行き先・題名・履歴の控えを持ち、ページ（`Page`）は要るあいだだけ持つ。
///
/// ページを持たないタブは二通りある。前回の閲覧から戻しただけで、まだ選ばれていないタブと、
/// しばらく使われずに眠らせたタブ。どちらも控え（`saved`）から履歴ごと起こせる。
/// ページを手放すと Web ビューごとページのプロセスも返るので、使っていないタブはメモリを取らない。
@MainActor
@Observable
final class Tab: Identifiable {
    nonisolated let id = UUID()
    /// 開いた順の通し番号。外部からタブを指すときの短い名前になる。
    let number: Int
    /// このタブのコンソール出力と読み込み失敗の記録。眠ってページを手放しても残る。
    let log = PageLog()
    /// ブックマークから開いたページなら、そのブックマーク。普通のタブなら `nil`。
    var bookmarkID: UUID?

    /// 生きているページ。読み込む前のタブと、眠らせたタブでは `nil`。
    private(set) var page: Page?
    /// 直近の読み込み失敗。次の読み込みが始まると消える。
    private(set) var failure: String?
    /// ページを持たないあいだの控え。起こすときに履歴ごと戻す。起こしたあとも、ページ自身の題名が届くまで題名に使う。
    private(set) var saved: SavedPage?
    /// 最後に読み込みを頼んだアドレス。読み込みに失敗してページのアドレスが空のままでも、
    /// タブの行き先を見失わないように持っておく（オフラインで起動したときなど）。
    private var requestedURL: URL?

    /// 最後に画面から外れた時刻。しばらく使われていないタブを眠らせるのに使う。
    @ObservationIgnored var lastShown = Date()

    @ObservationIgnored private let factory: PageFactory
    @ObservationIgnored private weak var opener: (any TabOpening)?
    @ObservationIgnored private let history: HistoryStore
    /// 次に確定する読み込みが、アドレスバーで確定して始めたものか。履歴で「打って訪れた」と数える。
    @ObservationIgnored private var typedNavigationPending = false
    /// 読み込み中の区間の印。Instruments で読み込みの始まりと終わりを見るため。
    @ObservationIgnored private var loadSignpost: OSSignpostIntervalState?

    init(
        number: Int,
        factory: PageFactory,
        opener: any TabOpening,
        history: HistoryStore,
        restoring saved: SavedPage? = nil
    ) {
        self.number = number
        self.factory = factory
        self.opener = opener
        self.history = history
        self.saved = saved
        requestedURL = saved?.url
    }

    // MARK: 表示用

    /// タブの行き先。読み込む前や眠っているタブ、読み込みに失敗したタブでも返す。
    var url: URL? { page?.url ?? requestedURL }

    /// ページ自身の題名が届くまで出しておく控えの題名。別のページへ移ったら使わない。
    private var savedTitle: String? {
        guard let saved, !saved.title.isEmpty,
              page?.url.map({ $0.isSameDestination(as: saved.url) }) ?? true
        else { return nil }
        return saved.title
    }

    /// ページを持っているか。持っていないタブには Web ビューを作らない。
    var hasContent: Bool { page != nil }

    /// 控えだけを持ち、選ばれるのを待っているか（戻しただけのタブと、眠らせたタブ）。
    var isAsleep: Bool { page == nil && saved != nil }

    var title: String {
        if let page, !page.title.isEmpty { return page.title }
        if let savedTitle { return savedTitle }
        if let url {
            // ローカルファイルなどホストのないURLは、ファイル名で代える。
            return url.host() ?? (url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)
        }
        return hasContent ? "読み込み中…" : "新規タブ"
    }

    var canGoBack: Bool { page?.canGoBack ?? false }
    var canGoForward: Bool { page?.canGoForward ?? false }
    var isLoading: Bool { page?.isLoading ?? false }
    var estimatedProgress: Double { page?.estimatedProgress ?? 0 }

    // MARK: 操作

    /// アドレスバーの入力（URLまたは検索語）を開き、開いたURLを返す。
    @discardableResult
    func open(_ input: String) -> URL? {
        guard let url = AddressResolver.resolve(input) else { return nil }
        open(typed: url)
        return url
    }

    /// アドレスバーで確定したアドレスを開く。
    func open(typed url: URL) {
        load(URLRequest(url: url))
        // 検索結果のページは打って訪れたものと数えない。検索語ごとの結果ページが補われてしまうため。
        typedNavigationPending = !AddressResolver.isSearch(url)
    }

    func load(_ request: URLRequest) {
        saved = nil
        failure = nil
        requestedURL = request.url
        livePage().load(request)
    }

    /// 控えだけのタブなら、ページを作って控えのところから続ける。戻る・進むの履歴も戻す。
    func wake() {
        guard page == nil, let saved else { return }
        failure = nil
        requestedURL = saved.url
        let page = livePage()
        if let state = saved.state, page.restore(state) { return }
        page.load(URLRequest(url: saved.url))
    }

    /// ページを手放して控えだけにする。ページのプロセスが返る。眠らせたら `true`。
    @discardableResult
    func sleep() -> Bool {
        guard page != nil, let snapshot = savedPage(includingState: true) else { return false }
        saved = snapshot
        requestedURL = snapshot.url
        closePage()
        return true
    }

    /// 閲覧状態として残す内容。行き先のないまっさらなタブは残さない。
    /// 履歴の控えは書き出すときだけ取る（変化を見張るたびに取ると、全タブぶん書き出しの手間がかかる）。
    func savedPage(includingState: Bool) -> SavedPage? {
        guard let url else { return nil }
        guard let page else {
            var copy = saved ?? SavedPage(url: url, title: "")
            copy.bookmark = bookmarkID
            if !includingState { copy.state = nil }
            return copy
        }
        return SavedPage(
            url: url,
            title: page.title.isEmpty ? savedTitle ?? "" : page.title,
            bookmark: bookmarkID,
            state: includingState ? page.interactionState : nil
        )
    }

    func goBack() {
        failure = nil
        page?.goBack()
    }

    func goForward() {
        failure = nil
        page?.goForward()
    }

    func reload() {
        guard let page else { return wake() }
        failure = nil
        page.reload()
    }

    func stop() {
        page?.stopLoading()
    }

    /// 失敗の表示を消して、下にある元のページを見せる。
    func dismissFailure() {
        failure = nil
    }

    /// タブを閉じるときに呼ぶ。ページを手放す。
    func tearDown() {
        closePage()
    }

    // MARK: 内部

    private func livePage() -> Page {
        if let page { return page }
        let page = factory.makePage(opener: opener, log: log) { [weak self] event in
            self?.handle(event)
        }
        self.page = page
        return page
    }

    private func closePage() {
        endLoadSignpost()
        page?.tearDown()
        page = nil
    }

    private func handle(_ event: Page.Event) {
        switch event {
        case .started:
            failure = nil
            endLoadSignpost()
            loadSignpost = Signposts.poster.beginInterval("ページの読み込み", id: Signposts.poster.makeSignpostID())
        case .committed:
            if let url = page?.url {
                history.recordVisit(to: url, typed: typedNavigationPending)
            }
            typedNavigationPending = false
        case .finished:
            endLoadSignpost()
            // 前のページと同じ題名なら変化の知らせが来ないので、読み終えたときにも入れる（空なら何もしない）。
            if let view = page?.webView, let url = view.url {
                history.setTitle(view.title ?? "", for: url)
            }
        case .titleChanged(let title):
            // 読み終えた時点ではまだ題名が届いていないことがあるので、届いたときにも入れる。
            if let url = page?.url {
                history.setTitle(title, for: url)
            }
        case .failed(let message):
            // 打ったアドレスが開けなかったときに、次のリンクの移動を打ったものと数えないように。
            typedNavigationPending = false
            endLoadSignpost()
            if let message {
                failure = message
                log.append(level: "navigation", message: message)
            }
        }
    }

    private func endLoadSignpost() {
        guard let loadSignpost else { return }
        Signposts.poster.endInterval("ページの読み込み", loadSignpost)
        self.loadSignpost = nil
    }
}
