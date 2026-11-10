import Foundation
import SwiftUI
import WebKit

/// ページ側から新しいタブを開いてもらうための窓口。
@MainActor
protocol TabOpening: AnyObject {
    func openTab(with request: URLRequest, inBackground: Bool)
}

/// ナビゲーションごとの可否判断。
///
/// `target="_blank"` や `window.open` のように新しいウインドウを求めるリンクと、
/// Commandキーを押しながらのクリックを、新しいタブに振り替える。
/// タブ管理側は弱参照で持つので、ページとの間に循環参照はできない。
@MainActor
struct NavigationDecider: WebPage.NavigationDeciding {
    weak var opener: (any TabOpening)?

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        let wantsNewWindow = action.target == nil
        let commandClick = action.navigationType == .linkActivated && action.modifierFlags.contains(.command)

        guard wantsNewWindow || commandClick, let opener, action.request.url != nil else {
            return .allow
        }
        opener.openTab(with: action.request, inBackground: commandClick)
        return .cancel
    }
}
