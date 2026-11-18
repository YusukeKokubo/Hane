import AppKit
import Foundation
import Testing
@testable import Hane

/// サイトのアイコンの選び方、取り方、覚え方。
@MainActor
@Suite final class FaviconTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "HaneFaviconTests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private let page = URL(string: "https://site.example/a/b")!

    @Test func choosesTheIconClosestTo32Pixels() {
        func link(_ path: String, _ kind: IconLink.Kind = .icon, sizes: String = "", type: String = "") -> IconLink {
            IconLink(url: URL(string: "https://site.example/\(path)")!, kind: kind, sizes: sizes, type: type)
        }
        let touch = link("touch.png", .touch, sizes: "180x180")
        let small = link("16.png", sizes: "16x16")
        let large = link("192.png", sizes: "192x192")
        let multi = link("favicon.ico", sizes: "16x16 32x32 48x48")
        let plain = link("plain.png")
        let vector = link("icon.svg")

        #expect(FaviconStore.choose([touch, small], for: page) == small.url, "rel=icon があれば apple-touch-icon より先に取る")
        #expect(FaviconStore.choose([touch], for: page) == touch.url)
        #expect(FaviconStore.choose([small, large], for: page) == large.url, "小さくてぼやけるものより、大きいものを縮める")
        #expect(FaviconStore.choose([large, multi, plain], for: page) == multi.url, "32を含むものがいちばん近い")
        #expect(FaviconStore.choose([small, plain], for: page) == plain.url)
        #expect(FaviconStore.choose([multi, vector], for: page) == vector.url, "ベクターは大きさを問わない")
    }

    @Test func fallsBackToTheSiteFaviconAndRefusesLocalFilesFromTheWeb() {
        let local = IconLink(url: URL(fileURLWithPath: "/etc/hosts"), kind: .icon)
        #expect(FaviconStore.choose([], for: page) == URL(string: "https://site.example/favicon.ico"))
        #expect(FaviconStore.choose([local], for: page) == URL(string: "https://site.example/favicon.ico"),
                "ネットの上のページから手元のファイルを読ませない")
        #expect(FaviconStore.choose([local], for: URL(fileURLWithPath: "/tmp/page.html")) == local.url)
        #expect(FaviconStore.choose([], for: URL(fileURLWithPath: "/tmp/page.html")) == nil)
    }

    @Test func shrinksTo32Pixels() throws {
        let png = try #require(FaviconStore.thumbnail(from: Self.png(.red, side: 180)))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == FaviconStore.pixelSize)
        #expect(bitmap.pixelsHigh == FaviconStore.pixelSize)
        #expect(FaviconStore.thumbnail(from: Data("not an image".utf8)) == nil)
    }

    /// 同じサイトでも、パスの一段目でアイコンが違うものはそこで覚える（docs.google.com のドキュメントとスプレッドシート）。
    @Test func remembersSectionsWhoseIconDiffersFromTheSite() throws {
        let favicons = FaviconStore()
        let red = try #require(FaviconStore.thumbnail(from: Self.png(.red, side: 32)))
        let blue = try #require(FaviconStore.thumbnail(from: Self.png(.blue, side: 32)))
        let document = URL(string: "https://docs.example/document/d/1/edit")!
        let sheet = URL(string: "https://docs.example/spreadsheets/d/2/edit")!

        favicons.remember(red, from: document)
        let site = try #require(favicons.image(for: URL(string: "https://docs.example/")!))
        #expect(favicons.image(for: document) === site, "まだサイトのアイコンがなければ、サイトのものとして覚える")

        favicons.remember(blue, from: sheet)
        let sheetIcon = try #require(favicons.image(for: sheet))
        #expect(sheetIcon !== site)
        #expect(favicons.image(for: URL(string: "https://docs.example/spreadsheets/d/3")!) === sheetIcon)
        #expect(favicons.image(for: document) === site)
        #expect(favicons.image(for: URL(string: "https://docs.example/presentation/d/4")!) === site, "知らない一段目はサイトのものを出す")

        favicons.remember(red, from: sheet)
        #expect(favicons.image(for: sheet) === site, "サイトと同じになったら一段目の分は捨てる")
        #expect(favicons.image(for: URL(string: "https://other.example/")!) == nil)
    }

    /// `data:` で示したアイコンはページだけのもの（Notion はページごとのアイコンを描いて差し込む）。
    /// サイトの分がまだ無いときだけ代わりに覚え、一段目の分には入れない。
    @Test func dataIconsBelongToThePage() async throws {
        let favicons = FaviconStore()
        let red = try Self.dataURL(.red)
        let blue = try Self.dataURL(.blue)
        let first = URL(string: "https://notes.example/p/first")!
        let second = URL(string: "https://notes.example/p/second")!

        let firstIcon = try #require(await favicons.update(page: first, links: [IconLink(url: red, kind: .icon)], userAgent: nil))
        let site = try #require(favicons.image(for: first), "サイトのアイコンがまだ無ければ、代わりに覚える")

        let secondIcon = try #require(await favicons.update(page: second, links: [IconLink(url: blue, kind: .icon)], userAgent: nil))
        #expect(secondIcon.image !== firstIcon.image)
        #expect(favicons.image(for: second) === site, "ほかのページのアイコンで、サイトや一段目の分を書き換えない")

        let again = await favicons.update(page: second, links: [IconLink(url: blue, kind: .icon)], userAgent: nil, current: secondIcon)
        #expect(again?.image === secondIcon.image, "同じものは縮め直さない")
        let rereadOther = await favicons.update(
            page: second, links: [IconLink(url: URL(string: "https://notes.example/count.png")!, kind: .icon)],
            userAgent: nil, current: secondIcon, rereading: true)
        #expect(rereadOther == nil, "読み直しでネットの上のアイコンに替わったら、ページの分は捨てる（取りには行かない）")
    }

    /// 読み終えた後にページがアイコンと題名を書き換えたら、タブはそのアイコンを出す。サイトの分は替えない。
    @Test func tabsFollowIconsThePageDrawsLater() async throws {
        let pages = directory.appending(path: "drawn")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try Self.png(.green, side: 64).write(to: pages.appending(path: "icon.png"))
        let drawn = try Self.dataURL(.purple).absoluteString
        let pageURL = pages.appending(path: "page.html")
        try """
            <title>Loading</title><link rel="icon" href="icon.png">
            <script>
            addEventListener('load', () => setTimeout(() => {
                document.querySelector('link[rel=icon]').href = '\(drawn)';
                document.title = 'Drawn';
            }, 300));
            </script>
            """.write(to: pageURL, atomically: true, encoding: .utf8)

        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()))
        let tab = try #require(store.selected)
        tab.open(pageURL.absoluteString)
        try await waitFor { tab.pageIcon != nil }
        let site = try #require(store.favicons.image(for: pageURL))
        #expect(tab.favicon === tab.pageIcon?.image)
        #expect(tab.favicon !== site)

        // 固定したら、開いていないときにも出せるよう、ブックマークのページのアイコンとして覚える。
        let bookmark = try #require(store.pin(tab.id))
        #expect(store.favicons.pageImage(for: pageURL) != nil)
        #expect(store.favicons.pageImage(for: pages.appending(path: "other.html")) == nil, "ほかのページには出さない")
        store.removeBookmark(bookmark.id)
        #expect(store.favicons.pageImage(for: pageURL) == nil, "ブックマークを消したら忘れる")
    }

    /// タブで読み終えたページのアイコンを取り、保存先があれば次に作ったときも読める。
    @Test func tabsFetchTheIconAndItIsRememberedAcrossLaunches() async throws {
        let pages = directory.appending(path: "pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try Self.png(.green, side: 64).write(to: pages.appending(path: "icon.png"))
        let pageURL = pages.appending(path: "page.html")
        try #"<title>Icon</title><link rel="icon" href="icon.png">"#.write(to: pageURL, atomically: true, encoding: .utf8)
        let saved = directory.appending(path: "favicons")

        let store = TabStore(factory: PageFactory(dataStore: .nonPersistent()), favicons: FaviconStore(directory: saved))
        let tab = try #require(store.selected)
        #expect(tab.favicon == nil)
        tab.open(pageURL.absoluteString)
        try await waitFor { tab.favicon != nil }

        let next = FaviconStore(directory: saved)
        #expect(next.image(for: pageURL) != nil, "ファイルに書いたものを次の起動で読む")
    }

    // MARK: 手伝い

    private static func png(_ color: NSColor, side: Int) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    private static func dataURL(_ color: NSColor) throws -> URL {
        try #require(URL(string: "data:image/png;base64," + png(color, side: 32).base64EncodedString()))
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
