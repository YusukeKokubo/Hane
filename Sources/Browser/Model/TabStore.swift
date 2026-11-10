import Foundation
import Observation

/// 開いているタブの一覧と選択状態。ウインドウ1枚につき1つ。
@MainActor
@Observable
final class TabStore: TabOpening {
    private(set) var tabs: [Tab] = []
    var selectedID: Tab.ID?

    /// アドレスバーにフォーカスを移してほしいときに増やす合図。
    private(set) var addressFocusRequest = 0

    @ObservationIgnored private let factory: PageFactory

    init(factory: PageFactory = PageFactory()) {
        self.factory = factory
        newTab()
    }

    var selected: Tab? {
        tabs.first { $0.id == selectedID }
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
        let tab = insertTab(after: selectedID)
        tab.load(request)
        if !inBackground { selectedID = tab.id }
    }

    /// タブを閉じる。最後の1枚を閉じたら `false` を返す（呼び出し側でウインドウを閉じる）。
    @discardableResult
    func close(_ id: Tab.ID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return !tabs.isEmpty }
        let tab = tabs.remove(at: index)
        tab.tearDown()

        if selectedID == id {
            selectedID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        return !tabs.isEmpty
    }

    @discardableResult
    func closeSelected() -> Bool {
        guard let selectedID else { return !tabs.isEmpty }
        return close(selectedID)
    }

    // MARK: 選択の移動

    func select(offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == selectedID }), !tabs.isEmpty else { return }
        let next = (current + offset + tabs.count) % tabs.count
        selectedID = tabs[next].id
    }

    /// 1始まりの番号で選ぶ。9は常に末尾のタブ。
    func select(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }

    func focusAddressBar() {
        addressFocusRequest += 1
    }

    private func insertTab(after anchor: Tab.ID?) -> Tab {
        let tab = Tab(factory: factory, opener: self)
        if let anchor, let index = tabs.firstIndex(where: { $0.id == anchor }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        return tab
    }
}
