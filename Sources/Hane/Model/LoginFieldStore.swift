import Foundation
import Observation

/// 教わった入れる場所の一つ。サイトのこの欄に、ログインのこの項目を入れる。
struct LoginFieldPlace: Codable, Equatable, Sendable {
    /// `HiddenElementStore.site(for:)` と同じ決め方のサイト。
    var site: String
    /// 欄を指す CSS セレクタ。
    var selector: String
    /// 入れる項目（`Credentials.Field.key`）。値そのものは持たない。
    var field: String
    var added: Date
}

/// 教わった入れる場所の一覧と保存。
///
/// アプリ全体で一つ（欄の場所はサイトの作りで決まり、どのプロファイルのどのアカウントで入るかによらない）。
/// 普段使いの実体だけ `~/Library/Application Support/Hane/login-fields.json` に保存する。
@MainActor
@Observable
final class LoginFieldStore {
    private(set) var places: [LoginFieldPlace] = []

    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            places = try decoder.decode([LoginFieldPlace].self, from: data)
        } catch {
            // 読めないファイルをそのまま上書きすると中身を失うので、横へ退避してから空で始める。
            let aside = fileURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            NSLog("入れる場所の一覧を読めなかったため \(aside.path(percentEncoded: false)) に退避しました: \(error)")
        }
    }

    func places(on site: String) -> [LoginFieldPlace] {
        places.filter { $0.site == site }
    }

    func field(at selector: String, on site: String) -> String? {
        places.first { $0.site == site && $0.selector == selector }?.field
    }

    /// その欄に入れる項目を決める。`nil` なら、その欄には入れないことにする（覚えたものを消す）。
    func set(_ field: String?, at selector: String, on site: String) {
        let before = places
        places.removeAll { $0.site == site && $0.selector == selector }
        if let field {
            places.append(LoginFieldPlace(site: site, selector: selector, field: field, added: Date()))
        }
        if places != before { save() }
    }

    /// そのサイトで教わった場所をすべて忘れ、忘れた数を返す。
    @discardableResult
    func removeAll(on site: String) -> Int {
        let before = places.count
        places.removeAll { $0.site == site }
        if places.count != before { save() }
        return before - places.count
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            // 手で直したり差分を見たりできるよう、整形して書く。
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(places).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("入れる場所の一覧を保存できませんでした: \(error)")
        }
    }
}
