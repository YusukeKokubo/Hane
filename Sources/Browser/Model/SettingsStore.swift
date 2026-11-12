import ControlWire
import Foundation
import Observation

/// 設定画面で変えられる値。
struct UserSettings: Codable, Equatable, Sendable {
    /// クリックなどの操作なしにページが開こうとする窓（ポップアップ）を止める。
    var blocksPopups = true

    init() {}

    // 項目を足しても前の版のファイルを読めるよう、ない項目は既定の値にする。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UserSettings()
        blocksPopups = try container.decodeIfPresent(Bool.self, forKey: .blocksPopups) ?? defaults.blocksPopups
    }
}

/// 設定の保存と、WebKit への反映。
///
/// 値は全タブで共有する環境設定（`SharedConfiguration.preferences`）へ入れるので、開いているタブにもその場で効く。
/// 保存するプロファイルだけ `settings.json` に書き、`dev` とテストでは保存しない。
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

    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        values = UserSettings()
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            do {
                values = try JSONDecoder().decode(UserSettings.self, from: data)
            } catch {
                // 壊れたファイルは既定の値で上書きされるまで残しておく（設定を一つ変えると書き直す）。
                NSLog("設定を読めなかったため既定の値で始めます: \(error)")
            }
        }
        // 共有の環境設定は最初から既定の値になっている。既定のままなら触らない
        // （テストでは操作の受け口ごとに作るので、別のテストが変えた値を戻してしまわないように）。
        if values != UserSettings() { apply() }
    }

    static func forCurrentProfile() -> SettingsStore {
        SettingsStore(fileURL: BrowserProfile.dataDirectory?.appending(path: "settings.json"))
    }

    private func apply() {
        SharedConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = !values.blocksPopups
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(values).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("設定を保存できませんでした: \(error)")
        }
    }
}
