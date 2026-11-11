import ControlWire
import Foundation

/// 前回開いていたページの控え。
struct SavedPage: Codable, Equatable, Sendable {
    var url: URL
    var title: String
    /// ブックマークから開いたページなら、そのブックマーク。
    var bookmark: UUID?
}

/// 閲覧状態。再起動したときにタブを戻すために使う。
///
/// 戻る・進むの履歴は含めない。`WebPage` には履歴を書き出して戻す手段がないため。
struct SavedSession: Codable, Equatable, Sendable {
    var version = 1
    /// バーに見える順。
    var pages: [SavedPage] = []
    /// `pages` の中で選んでいたページの位置。
    var selected: Int?
}

/// 閲覧状態の保存先。
///
/// 保存先を渡さなければ何も読み書きしない（開発用プロファイルとテスト）。
@MainActor
final class SessionStore {
    private let fileURL: URL?
    private var lastSaved: SavedSession?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    /// 普段使いのプロファイルなら保存し、それ以外は使い捨てにする。
    static func forCurrentProfile() -> SessionStore {
        guard BrowserProfile.isDefault else { return SessionStore() }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore(fileURL: base.appending(path: "Browser/session.json"))
    }

    var isPersistent: Bool { fileURL != nil }

    func load() -> SavedSession? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let session = try JSONDecoder().decode(SavedSession.self, from: data)
            lastSaved = session
            return session
        } catch {
            // 読めないファイルを次の保存で上書きすると手がかりも消えるので、横へ退避しておく。
            let aside = fileURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            NSLog("閲覧状態を読めなかったため \(aside.path(percentEncoded: false)) に退避しました: \(error)")
            return nil
        }
    }

    /// 前回書いた中身と同じなら書かない。題名や読み込み状態の細かな変化のたびに書き直さないため。
    func save(_ session: SavedSession) {
        guard let fileURL, session != lastSaved else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Signposts.interval("閲覧状態の書き出し") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(session).write(to: fileURL, options: .atomic)
            }
            lastSaved = session
        } catch {
            NSLog("閲覧状態を保存できませんでした: \(error)")
        }
    }
}
