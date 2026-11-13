import AppKit
import CryptoKit
import Foundation
import Observation
import WebKit

/// ページが `<link rel="icon">` などで示すアイコンの候補。
struct IconLink: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// `rel="icon"`（`shortcut icon` を含む）。
        case icon
        /// `rel="apple-touch-icon"`。大きいが、ほかに無いときの代わりになる。
        case touch
    }

    var url: URL
    var kind: Kind
    /// `sizes` 属性のまま（「16x16 32x32」「any」など）。
    var sizes: String = ""
    var type: String = ""
}

/// サイトのアイコン（favicon）。タブとブックマークの頭に出す。プロファイルごとに一つ。
///
/// WebKit は `WKWebView` にアイコンを渡す公開の API を持たないので、読み終えたページから候補を読み、自分で取りに行く。
/// 取ったものは小さな PNG に縮めて、サイトごとに覚える。眠っているタブやブックマークにも出すため、
/// 保存先があればファイルにも書き、次の起動では要るときに一つずつ読む。
///
/// 覚える単位はサイト（ホストとポート）で、同じサイトでもパスの一段目でアイコンが違うものだけ、その一段目でも覚える
/// （Google のドキュメントとスプレッドシートはどちらも docs.google.com にある）。
/// 一段目ごとに全部覚えると、記事ごとにパスの違うサイトでファイルが増え続けるため、サイトと違うときだけにする。
@MainActor
final class FaviconStore {
    /// 縮めた大きさ。タブでは16ポイントで出すので、Retina で2倍。
    static let pixelSize = 32
    /// これより大きいものは捨てる。アイコンとしては大きすぎ、縮めるのに手間がかかるだけなので。
    static let maximumBytes = 1 << 20

    /// 候補を読むページ内のスクリプト。ページのスクリプトから触れない場所（`WKContentWorld.defaultClient`）で走らせる。
    static let script = """
        const links = [];
        for (const link of document.querySelectorAll('link[rel][href]')) {
            const rel = link.relList;
            const kind = rel.contains('icon') ? 'icon'
                : rel.contains('apple-touch-icon') || rel.contains('apple-touch-icon-precomposed') ? 'touch' : null;
            if (kind) links.push({ href: link.href, kind, sizes: link.getAttribute('sizes') || '', type: link.type || '' });
        }
        return { links, userAgent: navigator.userAgent };
        """

    /// サイトか一段目ひとつぶんのアイコン。キーごとに見張れるよう、別々の Observable にする
    /// （一つにまとめると、どこかのアイコンが届くたびにすべてのタブを描き直す）。
    @MainActor
    @Observable
    final class Slot {
        fileprivate(set) var image: NSImage?
        @ObservationIgnored fileprivate var png: Data?

        init(png: Data?) {
            set(png)
        }

        fileprivate func set(_ png: Data?) {
            self.png = png
            image = png.flatMap(FaviconStore.image(fromPNG:))
        }
    }

    private struct Keys {
        /// ホストとポート。ホストのない `file:` ではフォルダ。
        var site: String
        /// パスの一段目まで。一段目がなければ `nil`。
        var section: String?
    }

    /// 保存先。`nil` ならメモリの中だけに持つ（使い捨ての実体とテスト）。
    private let directory: URL?
    private var slots: [String: Slot] = [:]
    /// この実体で取りに行ったアイコンのアドレス。同じページを読み直すたびに取りに行かないため。
    /// 次の起動では一度取り直すので、サイトがアイコンを変えても追いつく。
    private var requested: [String: URL] = [:]

    /// クッキーもキャッシュも持たない。ページとは別に取りに行くので、サイトにはログインしていない訪問に見える。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    init(directory: URL? = nil) {
        self.directory = directory
    }

    // MARK: 引く

    /// そのアドレスのページに出すアイコン。まだ取っていなければ `nil`。
    func image(for url: URL?) -> NSImage? {
        guard let url, let keys = Self.keys(for: url) else { return nil }
        if let section = keys.section, let image = slot(section).image { return image }
        return slot(keys.site).image
    }

    // MARK: 取りに行く

    /// 読み終えたページから候補を読んで取りに行く。
    func update(from page: Page, at url: URL) async {
        guard let result = try? await page.callJavaScript(Self.script, arguments: [:], contentWorld: .defaultClient) else { return }
        let found = Self.parse(result)
        await update(page: url, links: found.links, userAgent: found.userAgent)
    }

    /// 候補から一つ選んで取りに行き、覚える。前にこの実体で同じアイコンを取っていれば何もしない。
    func update(page: URL, links: [IconLink], userAgent: String?) async {
        guard let keys = Self.keys(for: page), let icon = Self.choose(links, for: page) else { return }
        let requestKey = keys.section ?? keys.site
        guard requested[requestKey] != icon else { return }
        requested[requestKey] = icon

        var request = URLRequest(url: icon)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        guard let (data, response) = try? await Self.session.data(for: request) else { return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        guard data.count <= Self.maximumBytes, let png = Self.thumbnail(from: data) else { return }
        remember(png, for: keys)
    }

    /// ページの中のスクリプト（`script`）の結果を読む。
    static func parse(_ result: Any?) -> (links: [IconLink], userAgent: String?) {
        let object = result as? [String: Any]
        let links = (object?["links"] as? [[String: Any]] ?? []).compactMap { entry -> IconLink? in
            guard let href = entry["href"] as? String, let url = URL(string: href),
                  let kind = (entry["kind"] as? String).flatMap(IconLink.Kind.init(rawValue:))
            else { return nil }
            return IconLink(url: url, kind: kind, sizes: entry["sizes"] as? String ?? "", type: entry["type"] as? String ?? "")
        }
        return (links, object?["userAgent"] as? String)
    }

    /// 候補から一つ選ぶ。`rel="icon"` を先に見て、32ピクセルに近いもの（ベクターなら大きさを問わず）を取る。
    /// 何も示していなければ、サイトの根元の `/favicon.ico` を試す。
    static func choose(_ links: [IconLink], for page: URL) -> URL? {
        let usable = links.filter { isFetchable($0.url, from: page) }
        if let best = usable.max(by: { score($0) < score($1) }) { return best.url }
        guard let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL
    }

    // MARK: 内部

    private func slot(_ key: String) -> Slot {
        if let slot = slots[key] { return slot }
        let slot = Slot(png: fileURL(for: key).flatMap { try? Data(contentsOf: $0) })
        slots[key] = slot
        return slot
    }

    /// サイトのアイコンは、サイトの入口で取ったものか、まだ無いときに取ったもので決める。
    /// それと違うアイコンだけを一段目で覚え、同じになったら一段目の分は捨てる。
    private func remember(_ png: Data, for keys: Keys) {
        let site = slot(keys.site)
        guard let section = keys.section, site.png != nil else {
            store(png, in: site, key: keys.site)
            return
        }
        store(png == site.png ? nil : png, in: slot(section), key: section)
    }

    private func store(_ png: Data?, in slot: Slot, key: String) {
        guard slot.png != png else { return }
        slot.set(png)
        guard let file = fileURL(for: key) else { return }
        do {
            if let png {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: file, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            NSLog("アイコンを保存できませんでした: \(error)")
        }
    }

    /// ファイル名にはキーをそのまま使わず、ハッシュにする（ホストやパスにファイル名で使えない文字が入りうる）。
    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).png")
    }

    private static func keys(for url: URL) -> Keys? {
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
            let site = host + (url.port.map { ":\($0)" } ?? "")
            let first = url.pathComponents.dropFirst().first
            return Keys(site: site, section: first.map { "\(site)/\($0)" })
        case "file":
            return Keys(site: "file://" + url.deletingLastPathComponent().path(percentEncoded: false))
        default:
            return nil
        }
    }

    /// ネットの上のページが手元のファイルを読ませることのないよう、`file:` のアイコンは `file:` のページにだけ許す。
    private static func isFetchable(_ url: URL, from page: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "data": true
        case "file": page.isFileURL
        default: false
        }
    }

    private static func score(_ link: IconLink) -> Double {
        let base: Double = link.kind == .icon ? 1000 : 0
        let isVector = link.type.lowercased() == "image/svg+xml"
            || link.url.pathExtension.lowercased() == "svg"
            || link.url.absoluteString.hasPrefix("data:image/svg")
        if isVector { return base + 500 }
        let sizes = link.sizes.lowercased().split(separator: " ").compactMap { size -> Int? in
            size == "any" ? 4096 : size.split(separator: "x").first.flatMap { Int($0) }
        }
        // 大きさの書いていないものは、ふつうの favicon.ico などとして 32 の次に置く。
        guard let nearest = sizes.min(by: { distance($0) < distance($1) }) else { return base + 400 }
        return base + 450 - distance(nearest)
    }

    /// 32 からの遠さ。小さいものはぼやけるので、同じだけ大きいものより遠く見る。
    private static func distance(_ size: Int) -> Double {
        size >= pixelSize ? Double(size - pixelSize) / 8 : Double(pixelSize - size) * 4
    }

    /// 縦横を保って32ピクセル四方に収め、PNG にする。読めない画像なら `nil`。
    static func thumbnail(from data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let side = CGFloat(pixelSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let scale = min(side / image.size.width, side / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func image(fromPNG png: Data) -> NSImage? {
        guard let image = NSImage(data: png) else { return nil }
        image.size = NSSize(width: pixelSize / 2, height: pixelSize / 2)
        return image
    }
}
