import ControlWire
import Foundation
import Observation

/// 前回開いていたページの控え。
struct SavedPage: Codable, Equatable, Sendable {
    var url: URL
    var title: String
    /// ブックマークから開いたページなら、そのブックマーク。
    var bookmark: UUID?
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
            NSLog("閲覧状態を読めなかったため \(aside.path(percentEncoded: false)) に退避しました: \(error)")
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
            NSLog("閲覧状態を保存できませんでした: \(error)")
        }
    }
}

/// 閲覧状態の変化を拾って書き出す。タブ管理一つにつき一つ。
///
/// 変化を一度拾うと同じ処理の回の終わりまでまとめて待ち、書き出してから見張り直す。
/// タイマーで定期的に書くのではなく、変化があったときだけ動く。見張るのは並び・アドレス・題名・選択だけで、
/// 履歴の控え（`interactionState`）は書き出すときにだけ取る（見張るたびに全タブぶん取ると重い）。
/// 手放すと見張りも止まる。
@MainActor
final class SessionRecorder {
    private let session: SessionStore
    private let snapshot: (_ includingState: Bool) -> SavedSession?

    /// 保存先のない閲覧状態（テストと使い捨ての実体）は見張らず、`saveNow()` のときだけメモリに残す。
    init(session: SessionStore, snapshot: @escaping (_ includingState: Bool) -> SavedSession?) {
        self.session = session
        self.snapshot = snapshot
        if session.isPersistent { watch() }
    }

    func saveNow() {
        guard let current = snapshot(true) else { return }
        session.save(current)
    }

    private func watch() {
        withObservationTracking {
            _ = snapshot(false)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.saveNow()
                self.watch()
            }
        }
    }
}
