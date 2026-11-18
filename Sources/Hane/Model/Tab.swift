import AppKit
import Observation
import os

/// タブ1枚ぶんの状態。行き先・題名・履歴の控えを持ち、ページ（`Page`）は要るあいだだけ持つ。
///
/// 中身は三つの形のどれかで、一つの値（`content`）で持つ。まっさらなタブ、控えだけを持って選ばれるのを待つタブ
/// （前回の閲覧から戻しただけのタブと、しばらく使われずに眠らせたタブ）、生きているページを持つタブ。
/// 控えからは履歴ごと起こせる。ページを手放すと Web ビューごとページのプロセスも返るので、使っていないタブはメモリを取らない。
@MainActor
@Observable
final class Tab: Identifiable {
    enum Content {
        /// 何も開いていない新しいタブ。
        case empty
        /// 控えだけを持ち、選ばれるのを待っている。
        case asleep(SavedPage)
        case live(LivePage)
    }

    struct LivePage {
        let page: Page
        /// 最後に読み込みを頼んだアドレス。読み込みに失敗してページのアドレスが空のままでも、
        /// タブの行き先を見失わないように持っておく（オフラインで起動したときなど）。
        var requested: URL?
        /// 控えから起こしたときの控え。ページ自身の題名が届くまで題名に使う。
        var placeholder: SavedPage?
    }

    nonisolated let id = UUID()
    /// 開いた順の通し番号。外部からタブを指すときの短い名前になる。
    let number: Int
    /// このタブのコンソール出力と読み込み失敗の記録。眠ってページを手放しても残る。
    let log = PageLog()

    private(set) var content: Content
    /// 直近の読み込み失敗。次の読み込みが始まると消える。
    private(set) var failure: String?
    /// ページを移ってから最初に題名が届いた回数。閲覧状態を書き出すきっかけに使う。
    /// 題名は読み終えた後に届くことがあり、行き先が変わった時点の書き出しには間に合わないため。
    /// その後の題名の変化では進めない（題名を書き換え続けるページで書き出しが続かないように）。
    private(set) var titleArrivals = 0

    /// 最後に画面から外れた時刻。しばらく使われていないタブを眠らせるのに使う。
    @ObservationIgnored var lastShown = Date()

    @ObservationIgnored private let factory: PageFactory
    @ObservationIgnored private weak var opener: (any TabOpening)?
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let favicons: FaviconStore
    /// 次に確定する読み込みがどこから来たか。履歴で来た道ごとに数える。分からなければ `nil`（`.other` と数える）。
    @ObservationIgnored private var pendingSource: VisitSource?
    /// ページを移ってから、まだ題名が届いていないか。
    @ObservationIgnored private var awaitingTitle = false
    /// 読み込み中の区間の印。Instruments で読み込みの始まりと終わりを見るため。
    @ObservationIgnored private var loadSignpost: OSSignpostIntervalState?

    init(
        number: Int,
        factory: PageFactory,
        opener: any TabOpening,
        history: HistoryStore,
        favicons: FaviconStore,
        restoring saved: SavedPage? = nil
    ) {
        self.number = number
        self.factory = factory
        self.opener = opener
        self.history = history
        self.favicons = favicons
        content = saved.map(Content.asleep) ?? .empty
    }

    // MARK: 表示用

    /// 生きているページ。まっさらなタブと、控えだけのタブでは `nil`。
    var page: Page? {
        if case .live(let live) = content { live.page } else { nil }
    }

    /// タブの行き先。読み込む前や眠っているタブ、読み込みに失敗したタブでも返す。
    var url: URL? {
        switch content {
        case .empty: nil
        case .asleep(let saved): saved.url
        case .live(let live): live.page.url ?? live.requested
        }
    }

    /// ページ自身の題名が届くまで出しておく控えの題名。別のページへ移ったら使わない。
    private var savedTitle: String? {
        switch content {
        case .empty:
            return nil
        case .asleep(let saved):
            return saved.title.isEmpty ? nil : saved.title
        case .live(let live):
            guard let saved = live.placeholder, !saved.title.isEmpty,
                  live.page.url.map({ $0.isSameDestination(as: saved.url) }) ?? true
            else { return nil }
            return saved.title
        }
    }

    /// ページを持っているか。持っていないタブには Web ビューを作らない。
    var hasContent: Bool { page != nil }

    /// 控えだけを持ち、選ばれるのを待っているか（戻しただけのタブと、眠らせたタブ）。
    var isAsleep: Bool {
        if case .asleep = content { true } else { false }
    }

    var title: String {
        if let page, !page.title.isEmpty { return page.title }
        if let savedTitle { return savedTitle }
        if let url {
            // ローカルファイルなどホストのないURLは、ファイル名で代える。
            return url.host() ?? (url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)
        }
        return hasContent ? "読み込み中…" : "新規タブ"
    }

    /// 行き先のサイトのアイコン。まだ取っていなければ `nil`。眠っているタブでも、覚えていれば返す。
    var favicon: NSImage? { favicons.image(for: url) }

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
        // 検索結果のページは打って訪れたものと数えない。検索語ごとの結果ページが補われてしまうため。
        load(URLRequest(url: url), from: AddressResolver.isSearch(url) ? nil : .typed)
    }

    /// `source` は、履歴でこの読み込みをどこから来たものと数えるか。
    func load(_ request: URLRequest, from source: VisitSource? = nil) {
        failure = nil
        pendingSource = source
        let page = self.page ?? makePage()
        content = .live(LivePage(page: page, requested: request.url))
        page.load(request)
    }

    /// 控えだけのタブなら、ページを作って控えのところから続ける。戻る・進むの履歴も戻す。
    func wake() {
        guard case .asleep(let saved) = content else { return }
        failure = nil
        let page = makePage()
        content = .live(LivePage(page: page, requested: saved.url, placeholder: saved))
        if let state = saved.state, page.restore(state) { return }
        page.load(URLRequest(url: saved.url))
    }

    /// ページを手放して控えだけにする。ページのプロセスが返る。眠らせたら `true`。
    @discardableResult
    func sleep() -> Bool {
        guard hasContent, let snapshot = savedPage() else { return false }
        closePage()
        content = .asleep(snapshot)
        return true
    }

    /// 閲覧状態として残す内容。行き先のないまっさらなタブは残さない。ブックマークとの結びつきはタブ管理が入れる。
    func savedPage() -> SavedPage? {
        switch content {
        case .empty:
            return nil
        case .asleep(var saved):
            saved.bookmark = nil
            saved.group = nil
            return saved
        case .live(let live):
            guard let url else { return nil }
            return SavedPage(
                url: url,
                title: live.page.title.isEmpty ? savedTitle ?? "" : live.page.title,
                state: live.page.interactionState
            )
        }
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

    /// 眠っているタブは起こせばどのみち取り直すので、起こすだけにする。
    func reloadFromOrigin() {
        guard let page else { return wake() }
        failure = nil
        page.reloadFromOrigin()
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
        content = .empty
    }

    // MARK: 内部

    private func makePage() -> Page {
        factory.makePage(opener: opener, log: log) { [weak self] event in
            self?.handle(event)
        }
    }

    /// ページの見張りと案内役を外す。手放すのは、呼んだ側が `content` を入れ替えたとき。
    private func closePage() {
        endLoadSignpost()
        page?.tearDown()
    }

    private func handle(_ event: Page.Event) {
        switch event {
        case .started:
            failure = nil
            endLoadSignpost()
            loadSignpost = Signposts.poster.beginInterval("ページの読み込み", id: Signposts.poster.makeSignpostID())
        case .committed:
            if let url = page?.url {
                history.recordVisit(to: url, from: pendingSource ?? .other)
            }
            pendingSource = nil
            awaitingTitle = true
        case .finished:
            endLoadSignpost()
            // 前のページと同じ題名なら変化の知らせが来ないので、読み終えたときにも入れる（空なら何もしない）。
            if let page, let url = page.url {
                history.setTitle(page.title, for: url)
                lookUpFavicon(of: page, at: url)
            }
        case .titleChanged(let title):
            if awaitingTitle {
                awaitingTitle = false
                titleArrivals += 1
            }
            // 読み終えた時点ではまだ題名が届いていないことがあるので、届いたときにも入れる。
            if let url = page?.url {
                history.setTitle(title, for: url)
            }
        case .failed(let message):
            // 打ったアドレスが開けなかったときに、次のリンクの移動を打ったものと数えないように。
            pendingSource = nil
            endLoadSignpost()
            if let message {
                failure = message
                log.append(level: "navigation", message: message)
            }
        case .linkFollowed:
            pendingSource = .link
        case .closeRequested:
            opener?.closeTab(self)
        case .keyCommand(let command):
            opener?.perform(command, from: self)
        }
    }

    /// ページが示すアイコンを読んで取りに行く。読み終えるたびに読むが、同じアイコンを取り直すことはない（`FaviconStore`）。
    private func lookUpFavicon(of page: Page, at url: URL) {
        Task { [weak page, favicons] in
            guard let page else { return }
            await favicons.update(from: page, at: url)
        }
    }

    private func endLoadSignpost() {
        guard let loadSignpost else { return }
        Signposts.poster.endInterval("ページの読み込み", loadSignpost)
        self.loadSignpost = nil
    }
}
