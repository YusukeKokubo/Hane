import ControlWire
import Foundation
import Observation

/// ⌥右クリックで選んで隠した要素。サイトごとに、要素を指すCSSセレクタを持つ。
struct HiddenElement: Codable, Equatable, Sendable {
    /// ホスト名（先頭の `www.` は除く）。ホストのない `file://` などではページのアドレス。
    var site: String
    var selector: String
    var added: Date
}

/// 隠した要素の一覧と保存。
///
/// アプリ全体で一つ（どのプロファイルで見ても、同じサイトの同じ広告は隠す）。
/// 普段使いの実体だけ `~/Library/Application Support/Hane/hidden-elements.json` に保存する。
@MainActor
@Observable
final class HiddenElementStore {
    private(set) var elements: [HiddenElement] = []

    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            elements = try decoder.decode([HiddenElement].self, from: data)
        } catch {
            // 読めないファイルをそのまま上書きすると中身を失うので、横へ退避してから空で始める。
            let aside = fileURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            NSLog("隠した要素の一覧を読めなかったため \(aside.path(percentEncoded: false)) に退避しました: \(error)")
        }
    }

    static func forInstance() -> HiddenElementStore {
        guard let directory = BrowserInstance.dataDirectory else { return HiddenElementStore() }
        return HiddenElementStore(fileURL: directory.appending(path: "hidden-elements.json"))
    }

    /// ページのアドレスから、隠す範囲になるサイトを決める。
    ///
    /// `www.` の有無で別のサイトとして扱うと、同じ広告をもう一度隠すことになるので外す。
    static func site(for url: URL) -> String? {
        if let host = url.host(), !host.isEmpty, ["http", "https"].contains(url.scheme) {
            let lowered = host.lowercased()
            return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
        }
        guard url.isFileURL else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        return components?.url?.absoluteString
    }

    func selectors(on site: String) -> [String] {
        elements.filter { $0.site == site }.map(\.selector)
    }

    /// 足したら `true`。同じものがあれば何もしない。
    @discardableResult
    func add(_ selector: String, on site: String) -> Bool {
        guard !elements.contains(where: { $0.site == site && $0.selector == selector }) else { return false }
        elements.append(HiddenElement(site: site, selector: selector, added: Date()))
        save()
        return true
    }

    /// そのサイトで隠した要素をすべて戻し、戻した数を返す。
    @discardableResult
    func removeAll(on site: String) -> Int {
        let before = elements.count
        elements.removeAll { $0.site == site }
        if elements.count != before { save() }
        return before - elements.count
    }

    /// コンテンツブロッカーのルール。サイトごとに1件へまとめる。
    var rules: [ContentRule] {
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for element in elements {
            if grouped[element.site] == nil { order.append(element.site) }
            grouped[element.site, default: []].append(element.selector)
        }
        return order.map { site in
            let trigger = site.contains("://")
                ? ContentRule.Trigger(urlFilter: "^" + ContentRule.Trigger.escape(site))
                : ContentRule.Trigger.onSite(site)
            return ContentRule.hide(grouped[site, default: []].joined(separator: ", "), on: trigger)
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            // 手で直したり差分を見たりできるよう、整形して書く。
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(elements).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("隠した要素の一覧を保存できませんでした: \(error)")
        }
    }
}
