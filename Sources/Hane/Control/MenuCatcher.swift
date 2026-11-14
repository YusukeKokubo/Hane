import AppKit

/// ページが出したメニュー（右クリックのメニューや選択欄の選択肢）を、出たそばから閉じて項目を控える。
///
/// 出たままだと持ち主の画面に残り、閉じるまでメインスレッドがメニューの中を回り続ける。
/// ページのメニューの項目を選ぶ道は持たない（選択欄は fill で選べる）。窓まわりの選択欄は、
/// 捕まえたメニューの項目の動作を `WindowElements` が直に呼ぶ。
@MainActor
final class MenuCatcher: NSObject {
    /// 出たメニューの項目。出なければ nil。
    private(set) var items: [String]?
    /// 出たメニュー。閉じたあとも項目の動作を呼べるよう持っておく。
    private(set) var menu: NSMenu?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(began), name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    /// メニューが回り始めたときに、メインスレッドで呼ばれる。
    @objc private func began(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        self.menu = menu
        items = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
        // 回り始めの知らせの中で閉じても効かず、メニューは出たままになった。一拍おいてから閉じる。
        Task { @MainActor in menu.cancelTrackingWithoutAnimation() }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }
}
