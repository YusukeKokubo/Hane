import Foundation
import Observation
import WebKit
import os

/// `WebPage` の足りない所を実行時の裏技で埋めている所（`SharedConfiguration` と `PopupWindows`）が、
/// 今の WebKit でも効いているかを、起動してから最初に読み込んだページで一度だけ確かめる。
///
/// どちらも外れてもページは開くので、普段使いでは黙って壊れる（タブを増やすとページのプロセスが溜まる、
/// ログインの小窓が開かない、など）。外れていたら窓の上の帯と `browserctl ui` に出す。
///
/// 確かめるには `WebPage` が中で作った Web ビューが要るが、`WebPage` はそれを公開していない。
/// そこで、読み込みを始めるページに「読み込み終えた」と知らせてくる一行のスクリプトを付け、
/// その知らせ（`WKScriptMessage.webView`）から受け取る。一度確かめたら受け口を外し、見張り続けはしない。
/// スクリプトは一つだけ外す手段がないので、付けたページに残るが、受け口がなければ何もしない。
@MainActor
@Observable
final class InternalsCheck {
    static let shared = InternalsCheck()

    /// 外れていたもの。空なら全部効いている。確かめる前は `nil`。
    private(set) var problems: [String]?
    /// 帯を閉じたか。その起動の間だけ覚える。
    var isDismissed = false

    /// 帯に出すものがあるか。
    var showsWarning: Bool { !isDismissed && !(problems ?? []).isEmpty }

    @ObservationIgnored private var isFinished = false
    @ObservationIgnored private lazy var receiver = Receiver { [weak self] webView in self?.finish(with: webView) }
    /// スクリプトを付けたページの受け口。確かめ終えたらすべてから受け口を外す。
    @ObservationIgnored private var probed: [WeakController] = []

    private static let handlerName = "browserInternalsCheck"
    private static let logger = Logger(subsystem: "Browser", category: "InternalsCheck")

    /// 読み込みを始める直前に呼ぶ。まだ確かめていなければ、このページに知らせのスクリプトを付ける。
    ///
    /// ページを作るときではなく読み込むときに付けるのは、戻したタブの多くは選ばれるまで読み込まないため。
    /// 作った順に付けると、読み込まれないページにスクリプトが残るだけになる。
    func probe(_ controller: WKUserContentController) {
        guard !isFinished else { return }
        probed.removeAll { $0.controller == nil }
        guard !probed.contains(where: { $0.controller === controller }) else { return }
        probed.append(WeakController(controller: controller))
        controller.add(receiver, name: Self.handlerName)
        controller.addUserScript(WKUserScript(
            source: "window.webkit.messageHandlers.\(Self.handlerName)?.postMessage(0)",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    /// 確かめる中身。テストからは自分で作った Web ビューを渡す。
    static func problems(in webView: WKWebView) -> [String] {
        SharedConfiguration.problems(in: webView) + [PopupWindows.problem(in: webView)].compactMap(\.self)
    }

    private func finish(with webView: WKWebView?) {
        guard !isFinished else { return }
        isFinished = true
        for entry in probed {
            entry.controller?.removeScriptMessageHandler(forName: Self.handlerName)
        }
        probed = []
        let found = webView.map(Self.problems(in:)) ?? ["確かめるための Web ビューを受け取れませんでした"]
        problems = found
        for problem in found {
            Self.logger.fault("\(problem, privacy: .public)")
        }
    }

    private struct WeakController {
        weak var controller: WKUserContentController?
    }

    /// 知らせを受ける。受け口は登録したものを強く持つので、`InternalsCheck` とは分けて循環させない。
    private final class Receiver: NSObject, WKScriptMessageHandler {
        let received: @MainActor (WKWebView?) -> Void

        init(received: @escaping @MainActor (WKWebView?) -> Void) {
            self.received = received
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            received(message.webView)
        }
    }
}
