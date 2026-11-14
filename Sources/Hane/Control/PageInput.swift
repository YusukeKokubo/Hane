import AppKit
import Foundation

/// 画面に出ているタブのページへ、利用者の本物の入力（マウスとキー）を渡す。ページだけを撮るのもここ。
///
/// 位置は `PageScripting` でページの中を測り、事象を Web ビューへ渡すのは `Page` に頼む。
/// 隠れた Web ビューは入力を受けないので、選ばれているタブかどうかを振り分ける側から受け取って確かめる。
@MainActor
final class PageInput {
    private let pages: PageScripting
    /// 選ばれているタブの ID。プロファイルを出している窓がなければ投げる。
    private let selectedTabID: @MainActor () throws -> UUID?

    init(pages: PageScripting, selectedTabID: @escaping @MainActor () throws -> UUID?) {
        self.pages = pages
        self.selectedTabID = selectedTabID
    }

    /// 本物の入力を渡せるページ。画面に出ているタブのページでなければ断る（隠れた Web ビューは入力を受けない）。
    private func inputPage(of tab: Tab) throws -> Page {
        guard let page = tab.page else { throw ControlError("このタブにはまだページがない。先に `open <URL>` を行うこと。") }
        guard try tab.id == selectedTabID() else {
            throw ControlError("画面に出ているタブにしか入力を渡せない。先に `select \(tab.number)` を行うこと。")
        }
        guard page.canReceiveInput else { throw ControlError("ページが窓に出ていない。") }
        return page
    }

    func click(_ reference: String, right: Bool, modifiers: NSEvent.ModifierFlags, on tab: Tab) async throws -> String {
        let page = try inputPage(of: tab)
        let (point, target) = try await pages.locate(reference, on: tab)
        tab.dismissFailure()
        let menus = MenuCatcher()
        defer { menus.stop() }
        guard page.click(at: point, right: right, modifiers: modifiers) else { throw ControlError("ページへマウスの事象を渡せなかった。") }
        var lines = [(right ? "right-clicked " : "clicked ") + target + " at \(Int(point.x)),\(Int(point.y))"]
        let state = try await pages.settled(tab)
        // メニューはページの返事を待ってから出るので、少し遅れて来る（試したときは20ミリ秒以内）。
        // 出ないことも多い（⌥右クリックの要素選びなど）ので、待ちすぎないよう区切る。右クリックは出やすいので長めに待つ。
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(right ? 500 : 100)
        while menus.items == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let items = menus.items {
            lines.append("menu (出たのですぐ閉じた。項目は選べない): " + (items.isEmpty ? "(項目なし)" : items.joined(separator: " / ")))
        }
        return (lines + [state]).joined(separator: "\n")
    }

    func hover(_ reference: String, on tab: Tab) async throws -> String {
        let page = try inputPage(of: tab)
        let (point, target) = try await pages.locate(reference, on: tab)
        guard page.moveMouse(to: point) else { throw ControlError("ページへマウスの事象を渡せなかった。") }
        try? await Task.sleep(for: .milliseconds(200))
        return "hovering \(target) at \(Int(point.x)),\(Int(point.y))"
            + (NSApp.isActive ? "" : "\n（アプリが裏にいるので、WebKit がポインタの動きを捨てて、ページには届かない。HANE_LAUNCH=front で起こして試すこと）")
    }

    /// キーを順に送り、画面に出るのを待つ。
    func press(_ specs: [String], on tab: Tab) async throws {
        let page = try inputPage(of: tab)
        // 先に全部読んでから送る。途中で書き損じが見つかって半端に送らないため。
        let keys = try specs.map(KeySpec.pageKey(from:))
        for key in keys {
            guard page.press(keyCode: key.code, characters: key.characters, ignoringModifiers: key.ignoringModifiers, modifiers: key.modifiers) else {
                throw ControlError("ページへキーを渡せなかった。")
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        // スクロールやタブの移動が画面に出るのを待つ。
        try? await Task.sleep(for: .milliseconds(300))
    }

    func screenshot(of tab: Tab, to path: String?, fullPage: Bool) async throws -> String {
        guard let page = tab.page else { throw ControlError("このタブにはまだページがない。") }
        guard try tab.id == selectedTabID() else {
            throw ControlError("画面に出ているタブしか撮れない。先に `select \(tab.number)` を行うこと。")
        }
        let data = try await page.snapshot(fullPage: fullPage)
        let destination = URL(filePath: path ?? NSTemporaryDirectory() + "hane-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: destination)
        return destination.path(percentEncoded: false)
    }
}
