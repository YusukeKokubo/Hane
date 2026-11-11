import Foundation
import Observation
import SwiftUI
import WebKit

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

    @ObservationIgnored private var monitor: Task<Void, Never>?

    init(number: Int, factory: PageFactory, opener: any TabOpening) {
        self.number = number
        page = factory.makePage(navigationDecider: NavigationDecider(opener: opener), log: log)
        monitor = Task { [weak self, page] in
            await Self.watchNavigations(of: page) { failure in
                self?.record(failure: failure)
            }
        }
    }

    // MARK: 表示用

    var title: String {
        if !page.title.isEmpty { return page.title }
        if let url = page.url {
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
        load(URLRequest(url: url))
        return url
    }

    func load(_ request: URLRequest) {
        hasContent = true
        failure = nil
        page.load(request)
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
        guard hasContent else { return }
        failure = nil
        page.reload()
    }

    func stop() {
        page.stopLoading()
    }

    private func record(failure: String?) {
        self.failure = failure
        if let failure {
            log.append(level: "navigation", message: failure)
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
        page.stopLoading()
    }

    // MARK: 読み込み結果の監視

    /// ページ内リンクも含めたすべてのナビゲーションを見張り、失敗を報告する。
    /// 失敗のたびに列が終わるので、キャンセルされるまで購読し直す。
    private static func watchNavigations(
        of page: WebPage,
        report: @MainActor (String?) -> Void
    ) async {
        while !Task.isCancelled {
            do {
                for try await event in page.navigations where event == .startedProvisionalNavigation {
                    report(nil)
                }
                return
            } catch WebPage.NavigationError.pageClosed {
                return
            } catch {
                if let message = Self.message(for: error) {
                    report(message)
                }
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
