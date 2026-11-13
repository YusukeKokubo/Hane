import ControlWire
import CryptoKit
import Foundation
import Observation
import WebKit

/// 広告ブロック。同梱のフィルタリストと、⌥右クリックで隠した要素を、
/// WebKit のコンテンツブロッカーとして全タブに効かせる。
///
/// 判定はページのプロセスの中で WebKit が行うので、アプリ側で常に動く処理はない。
/// フィルタリストのコンパイル（数秒かかる）はリストが変わったときだけで、結果は
/// `WKContentRuleListStore` に残り、次からは引いてくるだけになる。
@MainActor
@Observable
final class ContentBlocker: NSObject, WKScriptMessageHandler {
    enum FilterState: Equatable {
        /// 同梱のリストがない（`swift run` で動かしたときなど）。
        case unavailable
        case preparing
        /// 件数は、今回訳してコンパイルしたときだけ分かる。
        case ready(rules: Int?, skipped: Int?)
        case failed(String)
    }

    private(set) var filterState: FilterState = .preparing
    let hidden: HiddenElementStore

    @ObservationIgnored private let store: WKContentRuleListStore
    @ObservationIgnored private let filterFiles: [URL]
    @ObservationIgnored private var filterList: WKContentRuleList?
    @ObservationIgnored private var hiddenList: WKContentRuleList?
    /// ルールを効かせている先（プロファイルごとのページの設定の受け口）。プロファイルを離れたら勝手に外れるよう、弱く持つ。
    @ObservationIgnored private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private var preparation: Task<Void, Never>?
    /// 隠した要素のルールの作り直し。前のが終わってから次を始め、古い結果で上書きしないようにする。
    @ObservationIgnored private var hiddenUpdate: Task<Void, Never>?

    nonisolated private static let filterPrefix = "filters-"
    private static let hiddenIdentifier = "hidden-elements"

    init(store: WKContentRuleListStore, filterFiles: [URL], hidden: HiddenElementStore) {
        self.store = store
        self.filterFiles = filterFiles
        self.hidden = hidden
        super.init()
    }

    /// アプリ全体で一つ。普段使いの実体は WebKit の既定の置き場を使う。使い捨ての実体は名前ごとに置き場を分け、
    /// 開発用の実体が普段使いのコンパイル結果を古いものとして消さないようにする。
    static func forInstance() -> ContentBlocker {
        let directory = Bundle.main.resourceURL?.appending(path: "Filters")
        let files = (directory.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let store: WKContentRuleListStore
        if let instance = BrowserInstance.name {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            store = WKContentRuleListStore(url: caches.appending(path: "Hane/instances/\(instance)/ContentRuleLists")) ?? .default()
        } else {
            store = .default()
        }
        return ContentBlocker(store: store, filterFiles: files, hidden: .forInstance())
    }

    /// フィルタリストの状態を一行で。
    var filterSummary: String {
        switch filterState {
        case .unavailable: "フィルタリスト: 同梱されていない"
        case .preparing: "フィルタリスト: 準備中…"
        case .ready(let rules?, let skipped?): "フィルタリスト: 有効（\(rules)件、訳せず除外 \(skipped)件）"
        case .ready: "フィルタリスト: 有効"
        case .failed(let message): "フィルタリスト: 失敗（\(message)）"
        }
    }

    // MARK: ページへの取り付け

    /// プロファイルのページの設定に、今あるルールと要素選びのスクリプトを付ける。そのプロファイルの全ページに効く。
    ///
    /// 起動直後でまだルールが揃っていなくても待たない。揃った時点で付け足すと、
    /// それ以降の読み込みには効く（引いてくるだけなら数ミリ秒で、最初のページの資源にも間に合う）。
    func attach(to controller: WKUserContentController) {
        controllers.add(controller)
        for list in [filterList, hiddenList].compactMap(\.self) {
            controller.add(list)
        }
        controller.addUserScript(ElementPicker.userScript)
        controller.add(self, contentWorld: ElementPicker.world, name: ElementPicker.handlerName)
    }

    private func replace(_ old: WKContentRuleList?, with new: WKContentRuleList?) {
        for controller in controllers.allObjects {
            if let old { controller.remove(old) }
            if let new { controller.add(new) }
        }
    }

    // MARK: 準備

    /// 起動時に一度呼ぶ。何度呼んでも同じ準備を待つだけ。
    func prepare() async {
        if preparation == nil {
            preparation = Task {
                async let filters: Void = loadFilters()
                await updateHiddenRules()
                await filters
            }
        }
        await preparation?.value
    }

    /// 準備と、隠した要素のルールの作り直しが済むまで待つ。
    func settle() async {
        await prepare()
        await hiddenUpdate?.value
    }

    private func loadFilters() async {
        guard !filterFiles.isEmpty else {
            filterState = .unavailable
            return
        }
        filterState = .preparing
        let signpost = Signposts.poster.beginInterval("フィルタリストの準備")
        defer { Signposts.poster.endInterval("フィルタリストの準備", signpost) }
        do {
            let files = filterFiles
            let identifier = try await Task.detached(priority: .utility) { try Self.identifier(for: files) }.value
            let list: WKContentRuleList
            var counts: (rules: Int, skipped: Int)?
            if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                list = cached
            } else {
                // 訳すのも JSON にするのも重いので、メインスレッドから外す。
                let (json, rules, skipped) = try await Task.detached(priority: .utility) {
                    let lists = try files.map { try String(contentsOf: $0, encoding: .utf8) }
                    let conversion = FilterList.convert(lists)
                    return (try ContentRule.encode(conversion.rules), conversion.rules.count, conversion.skipped)
                }.value
                guard let compiled = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
                else { throw CocoaError(.coderValueNotFound) }
                list = compiled
                counts = (rules, skipped)
                await removeStaleFilterLists(keeping: identifier)
            }
            replace(filterList, with: list)
            filterList = list
            filterState = .ready(rules: counts?.rules, skipped: counts?.skipped)
        } catch {
            NSLog("フィルタリストを準備できませんでした: \(error)")
            filterState = .failed(String(describing: error))
        }
    }

    /// リストの中身と変換の版から決まる名前。どちらかが変わったら作り直す。
    nonisolated private static func identifier(for files: [URL]) throws -> String {
        var hash = SHA256()
        hash.update(data: Data("converter-\(FilterList.version)".utf8))
        for file in files {
            hash.update(data: Data(file.lastPathComponent.utf8))
            hash.update(data: try Data(contentsOf: file))
        }
        return filterPrefix + hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func removeStaleFilterLists(keeping identifier: String) async {
        let identifiers = await store.availableIdentifiers() ?? []
        for stale in identifiers where stale.hasPrefix(Self.filterPrefix) && stale != identifier {
            try? await store.removeContentRuleList(forIdentifier: stale)
        }
    }

    // MARK: 隠した要素

    /// 要素を隠すルールを足す。今開いているページの要素は、選んだときにページの側で隠している。
    func hide(_ selector: String, on site: String) async {
        guard hidden.add(selector, on: site) else { return }
        await updateHiddenRules()
    }

    /// そのサイトで隠した要素をすべて戻し、戻した数を返す。開いているページは読み込み直すまでそのまま。
    @discardableResult
    func unhideAll(on site: String) async -> Int {
        let count = hidden.removeAll(on: site)
        if count > 0 { await updateHiddenRules() }
        return count
    }

    /// 隠した要素のルールを作り直して全ページに配る。件数が少ないのでコンパイルは一瞬で済む。
    private func updateHiddenRules() async {
        let previous = hiddenUpdate
        let update = Task {
            await previous?.value
            await compileHiddenRules()
        }
        hiddenUpdate = update
        await update.value
    }

    private func compileHiddenRules() async {
        let rules = hidden.rules
        var list: WKContentRuleList?
        do {
            if rules.isEmpty {
                try? await store.removeContentRuleList(forIdentifier: Self.hiddenIdentifier)
            } else {
                list = try await store.compileContentRuleList(
                    forIdentifier: Self.hiddenIdentifier, encodedContentRuleList: try ContentRule.encode(rules))
            }
        } catch {
            NSLog("隠した要素のルールを作れませんでした: \(error)")
            return
        }
        replace(hiddenList, with: list)
        hiddenList = list
    }

    // MARK: ページからの知らせ

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // 選んだ要素の場所はページの申告ではなく、WebKit が知っているフレームのアドレスで決める。
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let selector = body["selector"] as? String,
              !selector.isEmpty, selector.count <= 2000,
              let url = message.frameInfo.request.url,
              let site = HiddenElementStore.site(for: url)
        else { return }
        Task { await hide(selector, on: site) }
    }
}
