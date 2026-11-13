import Foundation
import Observation
import WebKit

/// ダウンロードの一覧。プロファイルによらずアプリ全体で一つで、実体が動いている間だけ覚える。
///
/// ページから始まったダウンロード（`WKDownload`）を受け取り、保存先を決めて最後まで見届ける。
/// 進み具合は WebKit が知らせてくる間だけ写すので、ダウンロードがなければ何も動かない。
@MainActor
@Observable
final class Downloads {
    /// 始まった順。
    private(set) var items: [DownloadItem] = []

    /// 保存先。普段使いの実体ではダウンロードフォルダ、使い捨ての実体とテストでは一時フォルダの下。
    @ObservationIgnored let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// 普段使いの実体は持ち主のダウンロードフォルダへ、開発用などの使い捨ての実体は一時フォルダへ置く。
    static func forInstance(persistent: Bool, instance: String?) -> Downloads {
        if persistent, let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return Downloads(directory: folder)
        }
        return Downloads(directory: temporaryDirectory(for: instance ?? "test"))
    }

    static func temporaryDirectory(for name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Hane-downloads-\(name)")
    }

    var isActive: Bool { items.contains { $0.state == .running } }

    /// WebKit から渡されたダウンロードを引き受ける。
    func start(_ download: WKDownload) {
        let item = DownloadItem(download: download, downloads: self)
        items.append(item)
    }

    /// 終わったものを一覧から外す。保存したファイルはそのまま。
    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    /// 同じ名前のファイルがあれば「名前 2.拡張子」のように番号を足して、上書きしない名前を返す。
    func destination(for suggested: String) -> URL {
        // ページの言う名前にフォルダの区切りが混じっていても、保存先の外へ出さない。
        let cleaned = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = cleaned.isEmpty || cleaned.hasPrefix(".") ? "download" + cleaned : cleaned
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
            || items.contains(where: { $0.destination == candidate && $0.state == .running }) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

/// ダウンロード一件。`WKDownload` の案内役を兼ねる（WebKit は案内役を弱く持つので、一覧が持ち続ける）。
@MainActor
@Observable
final class DownloadItem: NSObject, Identifiable, WKDownloadDelegate {
    enum State: Equatable {
        case running, finished
        case failed(String)
        case cancelled
    }

    nonisolated let id = UUID()
    /// どこから取ってきたか。
    let source: URL?
    private(set) var state: State = .running
    /// 保存先。WebKit が名前を知らせてくるまでは `nil`。
    private(set) var destination: URL?
    /// 0〜1。大きさが分からないダウンロードでは `nil`。
    private(set) var fraction: Double?

    @ObservationIgnored private let download: WKDownload
    @ObservationIgnored private weak var downloads: Downloads?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(download: WKDownload, downloads: Downloads) {
        self.download = download
        self.downloads = downloads
        source = download.originalRequest?.url
        super.init()
        download.delegate = self
        // 進み具合の知らせは受け取るたびに来るので、画面が動くのは1%進んだときだけにする。
        observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            Task { @MainActor in self?.updateFraction(value) }
        }
    }

    var fileName: String {
        destination?.lastPathComponent ?? source?.lastPathComponent ?? "ダウンロード"
    }

    func cancel() {
        guard state == .running else { return }
        download.cancel { _ in }
        finish(.cancelled)
    }

    private func updateFraction(_ value: Double?) {
        guard state == .running else { return }
        guard let value else {
            fraction = nil
            return
        }
        if fraction.map({ abs($0 - value) >= 0.01 || value == 1 }) ?? true { fraction = value }
    }

    private func finish(_ state: State) {
        observation = nil
        self.state = state
    }

    // MARK: WKDownloadDelegate

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        guard let downloads else { return nil }
        do {
            try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        } catch {
            finish(.failed(error.localizedDescription))
            return nil
        }
        let destination = downloads.destination(for: suggestedFilename)
        self.destination = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        fraction = 1
        finish(.finished)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard state == .running else { return }
        finish(.failed(error.localizedDescription))
    }
}
