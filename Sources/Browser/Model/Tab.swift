import Foundation
import Observation
import SwiftUI
import WebKit
import os

/// タブ1枚ぶんの状態。`WebPage` を1つだけ所有する。
///
/// タイトル・URL・進捗は `WebPage` 自身が Observable なので、ここでは複製せず
/// そのまま読ませる。タブが `TabStore` から外れて参照が切れると `WebPage` も解放される。
@MainActor
@Observable
final class Tab: Identifiable {
    nonisolated let id = UUID()
    /// 開いた順の通し番号。外部からタブを指すときの短い名前になる。
    let number: Int
    let page: WebPage
    /// このタブのコンソール出力と読み込み失敗の記録。
    let log = PageLog()
    /// ブックマークから開いたページなら、そのブックマーク。普通のタブなら `nil`。
    var bookmarkID: UUID?

    /// 一度でも読み込みを始めたか。まっさらなタブでは Web ビューを作らない。
    private(set) var hasContent = false
    /// 直近の読み込み失敗。次の読み込みが始まると消える。
    private(set) var failure: String?
    /// 前回の閲覧から戻したページ。`hasContent` が `false` のうちは、選ばれるのを待っている。
    /// 戻したタブを一斉に読み込むと、タブの数だけページのプロセスが立ち上がってしまうため。
    private(set) var restored: SavedPage?
    /// 最後に読み込みを頼んだアドレス。読み込みに失敗して `page.url` が空のままでも、
    /// タブの行き先を見失わないように持っておく（オフラインで起動したときなど）。
    private var requestedURL: URL?

    @ObservationIgnored private let history: HistoryStore
    /// ページの設定の受け口。最初の読み込みで裏技が効いているかを確かめるのに使う（`InternalsCheck`）。
    @ObservationIgnored private let content: WKUserContentController
    /// 次に確定する読み込みが、アドレスバーで確定して始めたものか。履歴で「打って訪れた」と数える。
    @ObservationIgnored private var typedNavigationPending = false
    @ObservationIgnored private var monitor: Task<Void, Never>?
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
        self.history = history
        restored = saved
        requestedURL = saved?.url
        (page, content) = factory.makePage(opener: opener, log: log)
        monitor = Task { [weak self, page] in
            await Self.watchNavigations(of: page) { update in
                self?.handle(update)
            }
        }
    }

    // MARK: 表示用

    /// タブの行き先。読み込む前の戻したページや、読み込みに失敗したページでも返す。
    var url: URL? { page.url ?? requestedURL }

    /// 戻したページの読み込みを待つあいだ、ページ自身の題名が届くまで出しておく前回の題名。
    /// 別のページへ移ったら使わない。
    private var restoredTitle: String? {
        guard let restored, !restored.title.isEmpty,
              page.url.map({ $0.isSameDestination(as: restored.url) }) ?? true
        else { return nil }
        return restored.title
    }

    /// 戻しただけで、まだ読み込んでいないか。
    var isWaitingToLoad: Bool { restored != nil && !hasContent }

    var title: String {
        if !page.title.isEmpty { return page.title }
        if let restoredTitle { return restoredTitle }
        if let url {
            // ローカルファイルなどホストのないURLは、ファイル名で代える。
            return url.host() ?? (url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)
        }
        return hasContent ? "読み込み中…" : "新規タブ"
    }

    var canGoBack: Bool { !page.backForwardList.backList.isEmpty }
    var canGoForward: Bool { !page.backForwardList.forwardList.isEmpty }

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
        restored = nil
        start(request)
    }

    /// 戻しただけのページなら読み込みを始める。
    func loadRestoredPage() {
        guard isWaitingToLoad, let restored else { return }
        start(URLRequest(url: restored.url))
    }

    private func start(_ request: URLRequest) {
        hasContent = true
        failure = nil
        requestedURL = request.url
        InternalsCheck.shared.probe(content)
        page.load(request)
    }

    /// 閲覧状態として残す内容。行き先のないまっさらなタブは残さない。
    var savedPage: SavedPage? {
        guard let url else { return nil }
        return SavedPage(url: url, title: page.title.isEmpty ? restoredTitle ?? "" : page.title, bookmark: bookmarkID)
    }

    func goBack() {
        guard let item = page.backForwardList.backList.last else { return }
        failure = nil
        page.load(item)
    }

    func goForward() {
        guard let item = page.backForwardList.forwardList.first else { return }
        failure = nil
        page.load(item)
    }

    func reload() {
        guard hasContent else { return loadRestoredPage() }
        failure = nil
        page.reload()
    }

    func stop() {
        page.stopLoading()
    }

    private func handle(_ update: NavigationUpdate) {
        switch update {
        case .started:
            failure = nil
            endLoadSignpost()
            loadSignpost = Signposts.poster.beginInterval("ページの読み込み", id: Signposts.poster.makeSignpostID())
        case .committed:
            if let url = page.url {
                history.recordVisit(to: url, typed: typedNavigationPending)
            }
            typedNavigationPending = false
        case .finished:
            endLoadSignpost()
            if let url = page.url {
                history.setTitle(page.title, for: url)
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

    /// 失敗の表示を消して、下にある元のページを見せる。
    func dismissFailure() {
        failure = nil
    }

    /// タブを閉じるときに呼ぶ。監視タスクを止め、読み込みも打ち切る。
    func tearDown() {
        monitor?.cancel()
        monitor = nil
        endLoadSignpost()
        page.stopLoading()
    }

    private func endLoadSignpost() {
        guard let loadSignpost else { return }
        Signposts.poster.endInterval("ページの読み込み", loadSignpost)
        self.loadSignpost = nil
    }

    // MARK: 読み込み結果の監視

    private enum NavigationUpdate {
        case started, committed, finished
        /// 失敗の文言。利用者による中断のように見せなくてよい失敗なら `nil`。
        case failed(String?)
    }

    /// ページ内リンクも含めたすべてのナビゲーションを見張り、進み具合と失敗を報告する。
    /// 失敗のたびに列が終わるので、キャンセルされるまで購読し直す。
    private static func watchNavigations(
        of page: WebPage,
        report: @MainActor (NavigationUpdate) -> Void
    ) async {
        while !Task.isCancelled {
            do {
                for try await event in page.navigations {
                    switch event {
                    case .startedProvisionalNavigation: report(.started)
                    case .committed: report(.committed)
                    case .finished: report(.finished)
                    default: break
                    }
                }
                return
            } catch WebPage.NavigationError.pageClosed {
                return
            } catch {
                report(.failed(Self.message(for: error)))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// 表示すべき失敗なら文言を返す。利用者による中断などは `nil`。
    private static func message(for error: any Error) -> String? {
        var underlying = error
        if case WebPage.NavigationError.failedProvisionalNavigation(let inner) = error {
            underlying = inner
        }
        if case WebPage.NavigationError.webContentProcessTerminated = underlying {
            return "ページを表示するプロセスが終了しました。再読み込みしてください。"
        }
        let nsError = underlying as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return nil }
        // 102: ダウンロードなどでフレームの読み込みが打ち切られた場合。
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return nil }
        return nsError.localizedDescription
    }
}
