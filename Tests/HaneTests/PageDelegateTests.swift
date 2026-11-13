import Foundation
import Testing
import WebKit
@testable import Hane

/// ページが求めるもの（ダウンロード、利用者への問い合わせ、自分を閉じる）を受け止めているか。
/// 案内役で受けないと、WebKit はどれも黙って取り消す。
@MainActor
@Suite struct PageDelegateTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "page-delegate-\(UUID().uuidString)")
    private let downloads: Downloads
    private let store: TabStore

    init() {
        downloads = Downloads(directory: directory.appending(path: "Downloads"))
        store = TabStore(factory: PageFactory(dataStore: .nonPersistent(), downloads: downloads))
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func arrive(_ tab: Tab, at url: URL) async throws {
        for _ in 0..<150 where tab.page?.url != url || tab.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(tab.page?.url == url && !tab.isLoading)
    }

    private func finished() async throws -> DownloadItem {
        for _ in 0..<150 where downloads.items.first?.state != .finished {
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try #require(downloads.items.first)
        try #require(item.state == .finished, "\(item.state)")
        return item
    }

    /// `download` 属性のリンクは、保存先に同じ名前があれば番号を足して保存する。
    /// `file://` のページは互いに別のオリジンで、別のオリジンへの `download` 属性は WebKit が無視するので、`data:` で試す。
    @Test func downloadLinksAreSaved() async throws {
        let page = try write("links.html", #"<title>Links</title><a id="d" href="data:text/plain;base64,aGVsbG8=" download="saved.txt">dl</a>"#)
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        try "old".write(to: downloads.directory.appending(path: "saved.txt"), atomically: true, encoding: .utf8)
        let tab = store.open(URLRequest(url: page))
        try await arrive(tab, at: page)

        _ = try await tab.page?.callJavaScript("document.getElementById('d').click()", arguments: [:], contentWorld: .page)
        let item = try await finished()
        #expect(item.destination?.lastPathComponent == "saved 2.txt")
        #expect(try String(contentsOf: try #require(item.destination), encoding: .utf8) == "hello")
        #expect(tab.failure == nil, "ダウンロードになった読み込みを失敗と見せない")
        #expect(tab.page?.url == page, "ページはそのまま")
    }

    /// 表示できない型のファイルへ移ろうとしたら、ページを変えずにダウンロードする。
    @Test func unknownTypesAreDownloaded() async throws {
        let file = directory.appending(path: "blob.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3, 255]).write(to: file)
        let page = try write("start.html", "<title>Start</title>")
        let tab = store.open(URLRequest(url: page))
        try await arrive(tab, at: page)

        tab.load(URLRequest(url: file))
        let item = try await finished()
        #expect(try Data(contentsOf: try #require(item.destination)) == Data([0, 1, 2, 3, 255]))
        #expect(tab.failure == nil)
    }

    /// 窓に載っていないページ（裏のタブ）の問い合わせは、取り消したものとして待たずに答える。
    @Test func dialogsOutsideTheWindowAreCancelled() async throws {
        let page = try write("dialogs.html", "<title>Dialogs</title>")
        let tab = store.open(URLRequest(url: page))
        try await arrive(tab, at: page)
        let result = try await tab.page?.callJavaScript(
            "alert('a'); return [confirm('b'), prompt('c', 'd')]", arguments: [:], contentWorld: .page) as? [Any]
        #expect(result?.first as? Bool == false)
        #expect(result?.last is NSNull)
    }

    /// ページが自分を閉じたらタブを閉じる。最後の1枚なら空のタブに替える。
    @Test func windowCloseClosesTheTab() async throws {
        let page = try write("closing.html", "<title>Closing</title>")
        let first = store.tabs[0]
        let tab = store.open(URLRequest(url: page))
        try await arrive(tab, at: page)

        _ = try await tab.page?.callJavaScript("window.close()", arguments: [:], contentWorld: .page)
        for _ in 0..<50 where store.tabs.contains(where: { $0 === tab }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.tabs.map(\.id) == [first.id])

        first.load(URLRequest(url: page))
        try await arrive(first, at: page)
        _ = try await first.page?.callJavaScript("window.close()", arguments: [:], contentWorld: .page)
        for _ in 0..<50 where store.tabs.first === first {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.tabs.count == 1)
        #expect(store.tabs.first !== first)
        #expect(store.selected?.hasContent == false, "新しい空のタブ")
    }

    /// 小窓の中のページもタブと同じ案内役を持ち、ダウンロードを受ける。
    @Test func popupsHandleDownloadsLikeTabs() async throws {
        let opener = try write("opener.html", "<title>Opener</title>")
        let inside = try write("inside.html", #"<title>Inside</title><a id="d" href="data:text/plain;base64,aGVsbG8=" download="popup.txt">dl</a>"#)
        let tab = store.open(URLRequest(url: opener))
        try await arrive(tab, at: opener)

        _ = try await tab.page?.callJavaScript(
            "window.open('\(inside.absoluteString)', 'p', 'width=400,height=300'); return 1", arguments: [:], contentWorld: .page)
        // 小窓の一覧はアプリ全体で一つなので、開いた側で見分ける。
        let popup = try #require(PopupWindows.windows.first { $0.opener === store })
        defer { popup.close() }
        for _ in 0..<150 where popup.page.url != inside || popup.page.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(popup.page.url == inside)

        _ = try await popup.page.callJavaScript("document.getElementById('d').click()", arguments: [:], contentWorld: .page)
        let item = try await finished()
        #expect(item.destination?.lastPathComponent == "popup.txt")
        #expect(store.tabs.count == 2, "小窓の中のダウンロードでタブを増やさない")
    }
}
