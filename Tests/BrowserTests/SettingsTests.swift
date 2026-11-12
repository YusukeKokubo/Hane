import Foundation
import Testing
@testable import Browser

@MainActor
@Suite struct SettingsTests {
    private let file = FileManager.default.temporaryDirectory
        .appending(path: "settings-test-\(UUID().uuidString)")
        .appending(path: "settings.json")

    @Test func savesChangesAndReadsThemBack() throws {
        // 環境設定はほかのテストと共有なので、前の値に戻す（待ちのない関数なので、途中で割り込まれない）。
        let before = SharedConfiguration.preferences.javaScriptCanOpenWindowsAutomatically
        defer {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            SharedConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = before
        }
        let settings = SettingsStore(fileURL: file)
        #expect(settings.blocksPopups)
        // 既定の値のままなら書かない。
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

        settings.blocksPopups = false
        #expect(SharedConfiguration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(!SettingsStore(fileURL: file).blocksPopups)
    }

    /// 項目を足した版でも、前の版が書いたファイルを読める。
    @Test func missingKeysFallBackToDefaults() throws {
        let settings = try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
        #expect(settings == UserSettings())
    }

    @Test func brokenFileStartsFromDefaults() throws {
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(SettingsStore(fileURL: file).blocksPopups)
    }
}
