import ControlWire
import Foundation
import Observation

/// 前回開いていたページの控え。
struct SavedPage: Codable, Equatable, Sendable {
    var url: URL
    var title: String
    /// ブックマークから開いたページなら、そのブックマーク。
    var bookmark: UUID?
    /// 組に入っている普通のタブなら、その組。前の版のファイルにはないので省ける。
    var group: UUID?
    /// 戻る・進むの履歴と今の位置の控え（`WKWebView.interactionState`）。中身は WebKit だけが読める。
    /// 前の版のファイルにはないので省ける。
    var state: Data?
}

/// 閲覧状態。再起動したときにタブを戻すために使う。
///
/// 戻る・進むの履歴もページごとに含めるので、再起動しても戻れる。
struct SavedSession: Codable, Equatable, Sendable {
    var version = 1
    /// バーに見える順。
    var pages: [SavedPage] = []
    /// `pages` の中で選んでいたページの位置。
    var selected: Int?
    /// 普通のタブの組。前の版のファイルにはないので省ける。
    var groups: [TabGroup]?
    /// バーに出していた組。`nil` はどの組にも入っていないタブ。
    var currentGroup: UUID?
}

/// 閲覧状態の保存先。
///
/// 保存先を渡さなければファイルには書かず、最後に保存した中身をメモリに持って `load()` で返す
/// （使い捨ての実体でプロファイルを行き来したときにタブを戻すため。テストでもこちら）。
@MainActor
final class SessionStore {
    private let fileURL: URL?
    private var lastSaved: SavedSession?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    var isPersistent: Bool { fileURL != nil }

    func load() -> SavedSession? {
        guard let fileURL else { return lastSaved }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let session = try JSONDecoder().decode(SavedSession.self, from: data)
            lastSaved = session
            return session
        } catch {
            // 読めないファイルを次の保存で上書きすると手がかりも消えるので、横へ退避しておく。
            let aside = fileURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            AppLog.logger.error("閲覧状態を読めなかったため \(aside.path(percentEncoded: false), privacy: .public) に退避しました: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 前回書いた中身と同じなら書かない。題名や読み込み状態の細かな変化のたびに書き直さないため。
    func save(_ session: SavedSession) {
        guard session != lastSaved else { return }
        guard let fileURL else {
            lastSaved = session
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Signposts.interval("閲覧状態の書き出し") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(session).write(to: fileURL, options: .atomic)
            }
            lastSaved = session
        } catch {
            AppLog.logger.error("閲覧状態を保存できませんでした: \(String(describing: error), privacy: .public)")
        }
    }
}

/// 閲覧状態の変化を拾って書き出す。タブ管理一つにつき一つ。
///
/// 変化を一度拾うと同じ処理の回の終わりまでまとめて待ち、書き出してから見張り直す。
/// タイマーで定期的に書くのではなく、変化があったときだけ動く。何を見張るかは持ち主が `watched` で決める
/// （タブ管理は並び・行き先・選択だけを見張り、題名は見張らない）。手放すと見張りも止まる。
@MainActor
final class SessionRecorder {
    private let session: SessionStore
    private let watched: () -> Void
    private let snapshot: () -> SavedSession?

    /// `watched` は書き出すきっかけになる値に触れるだけの処理、`snapshot` は書き出す中身。
    /// 保存先のない閲覧状態（テストと使い捨ての実体）は見張らず、`saveNow()` のときだけメモリに残す。
    init(session: SessionStore, watched: @escaping () -> Void, snapshot: @escaping () -> SavedSession?) {
        self.session = session
        self.watched = watched
        self.snapshot = snapshot
        if session.isPersistent { watch() }
    }

    func saveNow() {
        guard let current = snapshot() else { return }
        session.save(current)
    }

    private func watch() {
        withObservationTracking {
            watched()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.saveNow()
                self.watch()
            }
        }
    }
}
