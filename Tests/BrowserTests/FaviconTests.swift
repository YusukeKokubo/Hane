import AppKit
import Foundation
import Testing
@testable import Browser

/// サイトのアイコンの選び方、取り方、覚え方。
@MainActor
@Suite final class FaviconTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "BrowserFaviconTests-\(UUID().uuidString)")

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
    @Test func remembersSectionsWhoseIconDiffersFromTheSite() async throws {
        let favicons = FaviconStore()
        let red = try Self.dataURL(.red)
        let blue = try Self.dataURL(.blue)
        let document = URL(string: "https://docs.example/document/d/1/edit")!
        let sheet = URL(string: "https://docs.example/spreadsheets/d/2/edit")!

        await favicons.update(page: document, links: [IconLink(url: red, kind: .icon)], userAgent: nil)
        let site = try #require(favicons.image(for: URL(string: "https://docs.example/")!))
        #expect(favicons.image(for: document) === site, "まだサイトのアイコンがなければ、サイトのものとして覚える")

        await favicons.update(page: sheet, links: [IconLink(url: blue, kind: .icon)], userAgent: nil)
        let sheetIcon = try #require(favicons.image(for: sheet))
        #expect(sheetIcon !== site)
        #expect(favicons.image(for: URL(string: "https://docs.example/spreadsheets/d/3")!) === sheetIcon)
        #expect(favicons.image(for: document) === site)
        #expect(favicons.image(for: URL(string: "https://docs.example/presentation/d/4")!) === site, "知らない一段目はサイトのものを出す")

        await favicons.update(page: sheet, links: [IconLink(url: red, kind: .icon)], userAgent: nil)
        #expect(favicons.image(for: sheet) === site, "サイトと同じになったら一段目の分は捨てる")
        #expect(favicons.image(for: URL(string: "https://other.example/")!) == nil)
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
