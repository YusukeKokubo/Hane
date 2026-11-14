import ControlWire
import Foundation
import Observation

/// 設定画面で変えられる値。
struct UserSettings: Codable, Equatable, Sendable {
    /// クリックなどの操作なしにページが開こうとする窓（ポップアップ）を止める。
    var blocksPopups = true
    /// ページの中で文字のキーだけで操作する（`KeyNavigation`）。
    var usesKeyNavigation = true
    /// キー操作を使わないサイト。ページ自身が文字のキーで操作するサイトのため。ホスト名で、サブドメインも含む。
    var keyNavigationExcludedSites = ["mail.google.com", "calendar.google.com"]

    init() {}

    // 項目を足しても前の版のファイルを読めるよう、ない項目は既定の値にする。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UserSettings()
        blocksPopups = try container.decodeIfPresent(Bool.self, forKey: .blocksPopups) ?? defaults.blocksPopups
        usesKeyNavigation = try container.decodeIfPresent(Bool.self, forKey: .usesKeyNavigation) ?? defaults.usesKeyNavigation
        keyNavigationExcludedSites = try container.decodeIfPresent([String].self, forKey: .keyNavigationExcludedSites)
            ?? defaults.keyNavigationExcludedSites
    }
}

/// 設定の保存と、WebKit への反映。
///
/// 値は全タブで共有する環境設定（`SharedConfiguration.preferences`）へ入れるので、開いているタブにもその場で効く。
/// プロファイルによらずアプリ全体で一つ。普段使いの実体だけ `settings.json` に書き、使い捨ての実体とテストでは保存しない。
@MainActor
@Observable
final class SettingsStore {
    var values: UserSettings {
        didSet {
            guard values != oldValue else { return }
            apply()
            save()
        }
    }

    var blocksPopups: Bool {
        get { values.blocksPopups }
        set { values.blocksPopups = newValue }
    }

    var usesKeyNavigation: Bool {
        get { values.usesKeyNavigation }
        set { values.usesKeyNavigation = newValue }
    }

    var keyNavigationExcludedSites: [String] { values.keyNavigationExcludedSites }

    /// 打ったものや貼ったもの（URL でもよい）を、キー操作を使わないサイトに足す。足せたら `true`。
    @discardableResult
    func excludeFromKeyNavigation(_ input: String) -> Bool {
        guard let site = KeyNavigation.site(from: input) else { return false }
        if !values.keyNavigationExcludedSites.contains(site) {
            values.keyNavigationExcludedSites.append(site)
        }
        return true
    }

    func removeKeyNavigationExclusion(_ site: String) {
        values.keyNavigationExcludedSites.removeAll { $0 == site }
    }

    /// `host` でキー操作を使わないことにしているか（親のドメインで外したものも含む）。
    func isExcludedFromKeyNavigation(_ host: String) -> Bool {
        KeyNavigation.Policy.match(host: host, in: values.keyNavigationExcludedSites) != nil
    }

    /// メニューから今のサイトを外す・戻す。戻すときは、そのホストに当たる項目（親のドメインのものも）を外す。
    func setKeyNavigation(excluded: Bool, on host: String) {
        if excluded {
            excludeFromKeyNavigation(host)
        } else {
            while let site = KeyNavigation.Policy.match(host: host, in: values.keyNavigationExcludedSites) {
                removeKeyNavigationExclusion(site)
            }
        }
    }

    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        values = UserSettings()
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            do {
                values = try JSONDecoder().decode(UserSettings.self, from: data)
            } catch {
                // 壊れたファイルは既定の値で上書きされるまで残しておく（設定を一つ変えると書き直す）。
                AppLog.logger.error("設定を読めなかったため既定の値で始めます: \(String(describing: error), privacy: .public)")
            }
        }
        // 共有の環境設定は最初から既定の値になっている。既定のままなら触らない
        // （テストでは操作の受け口ごとに作るので、別のテストが変えた値を戻してしまわないように）。
        if values != UserSettings() { apply() }
    }

    static func forInstance() -> SettingsStore {
        SettingsStore(fileURL: BrowserInstance.dataDirectory?.appending(path: "settings.json"))
    }

    private func apply() {
        SharedConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = !values.blocksPopups
        KeyNavigation.policy = KeyNavigation.Policy(values)
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(values).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.logger.error("設定を保存できませんでした: \(String(describing: error), privacy: .public)")
        }
    }
}
