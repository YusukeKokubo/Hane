import Foundation

/// フレームごとの通信の記録を集めて、文字か JSON に整える。
///
/// ページが自分で持っている記録を命令のときだけ読むので、普段の閲覧には何も足さない。
/// フレームの辿り方は `PageScripting` のものを使う。
@MainActor
struct PageRequests {
    let pages: PageScripting

    /// 一つのフレームが読み込んだものと、要素が指しているのに記録がないもの。
    struct FrameRequests {
        /// main、frame 1、frame 1.h1 など。
        var name: String
        /// iframe の名札（iframe#ad など）。主フレームは空。
        var element = ""
        var url = ""
        /// このフレームの時刻の起点（`performance.timeOrigin`。1970年からのミリ秒）。
        var origin: Double = 0
        var entries: [RequestEntry] = []
        var missing: [MissingResource] = []
        var bufferFull = false
        var error: String?
    }

    struct RequestEntry {
        var type: String
        var url: String
        /// フレームの時刻の起点からのミリ秒。
        var start: Double
        var duration: Double
        var transfer: Double
        var encoded: Double
        var decoded: Double
        var transport: String
    }

    struct MissingResource {
        var type: String
        var url: String
        var hint: String
    }

    struct Filter {
        /// 小文字にした部分一致。
        var url: String?
        var types: Set<String>?

        func matches(type: String, url: String) -> Bool {
            (types?.contains(type.lowercased()) ?? true) && (self.url.map { url.lowercased().contains($0) } ?? true)
        }
    }

    /// WebKit が一つの文書で持つ資源の記録の上限（Resource Timing の既定）。あふれた後の読み込みは記録されない。
    private static let resourceTimingCapacity = 250

    // MARK: 集める

    /// 主フレームから子フレームを（見えていないものも）辿り、フレームごとの通信の記録を集める。
    func read(of tab: Tab) async throws -> [FrameRequests] {
        var frames: [FrameRequests] = []
        try await collect(into: &frames, frame: PageScripting.Frame(), path: [], on: tab)
        return frames
    }

    private func collect(
        into frames: inout [FrameRequests], frame: PageScripting.Frame, path: [String], element: String = "", on tab: Tab
    ) async throws {
        let value = try await pages.scriptValue(PageScripts.requests, on: tab, in: frame.info)
        guard let object = value as? [String: Any] else { throw ControlError("通信の記録を読めなかった。") }
        let name = path.isEmpty ? "main" : "frame " + path.joined(separator: ".")
        let number = { (key: String, from: [String: Any]) in (from[key] as? NSNumber)?.doubleValue ?? 0 }
        frames.append(FrameRequests(
            name: name, element: element,
            url: object["url"] as? String ?? "",
            origin: number("origin", object),
            entries: (object["entries"] as? [[String: Any]] ?? []).map { entry in
                RequestEntry(
                    type: entry["type"] as? String ?? "other", url: entry["url"] as? String ?? "",
                    start: number("start", entry), duration: number("duration", entry),
                    transfer: number("transfer", entry), encoded: number("encoded", entry), decoded: number("decoded", entry),
                    transport: entry["protocol"] as? String ?? "")
            },
            missing: (object["missing"] as? [[String: Any]] ?? []).map { item in
                MissingResource(type: item["type"] as? String ?? "", url: item["url"] as? String ?? "", hint: item["hint"] as? String ?? "")
            },
            bufferFull: Int(number("resources", object)) >= Self.resourceTimingCapacity))

        // 見えているものは snapshot と同じ番号で、見えていないものは h1、h2 と名付ける（--frame では指せない）。
        var hidden = 0
        for (index, child) in (object["frames"] as? [[String: Any]] ?? []).enumerated() {
            let visible = (child["visible"] as? NSNumber)?.intValue ?? -1
            let part: String
            if visible >= 0 {
                part = String(visible + 1)
            } else {
                hidden += 1
                part = "h\(hidden)"
            }
            let label = child["label"] as? String ?? ""
            // 入れ子が深すぎるおかしなページで回り続けないよう区切る。
            guard path.count < 16 else { continue }
            do {
                let next = try await pages.frame(at: [index], from: frame, on: tab, every: true)
                try await collect(into: &frames, frame: next, path: path + [part], element: label, on: tab)
            } catch {
                // 読めないフレームがあっても、ほかは出す。
                let reason = (error as? ControlError)?.message ?? ControlError.describe(error)
                frames.append(FrameRequests(name: "frame " + (path + [part]).joined(separator: "."), element: label, error: reason))
            }
        }
    }

    // MARK: 整える

    /// 絞り込んだ記録を、フレームをまたいで始まった順に並べ、上限までを選ぶ。
    /// 返すのはフレームごとの選んだ記録（主フレームの時刻の起点からのミリ秒つき）と、上限で省いた数。
    private static func select(
        _ frames: [FrameRequests], filter: Filter, limit: Int
    ) -> (rows: [[(entry: RequestEntry, at: Double)]], omitted: Int) {
        let base = frames.first?.origin ?? 0
        var all: [(frame: Int, entry: RequestEntry, at: Double)] = []
        for (index, frame) in frames.enumerated() {
            for entry in frame.entries where filter.matches(type: entry.type, url: entry.url) {
                all.append((index, entry, frame.origin + entry.start - base))
            }
        }
        all.sort { $0.at < $1.at }
        let shown = all.prefix(max(0, limit))
        var rows = Array(repeating: [(entry: RequestEntry, at: Double)](), count: frames.count)
        for item in shown { rows[item.frame].append((item.entry, item.at)) }
        return (rows, all.count - shown.count)
    }

    static func text(_ frames: [FrameRequests], filter: Filter, limit: Int) -> String {
        let (rows, omitted) = select(frames, filter: filter, limit: limit)
        var lines: [String] = []
        for (index, frame) in frames.enumerated() {
            lines.append(frame.name + (frame.element.isEmpty ? "" : " (\(frame.element))") + (frame.url.isEmpty ? "" : " — " + frame.url))
            if let error = frame.error {
                lines.append("  （中を読めなかった: \(error)）")
                continue
            }
            if frame.bufferFull {
                lines.append("  （資源の記録が上限の \(resourceTimingCapacity) 件に達している。これより後の読み込みは記録されず、not loaded に誤って出ることもある）")
            }
            if rows[index].isEmpty {
                let matched = frame.entries.contains { filter.matches(type: $0.type, url: $0.url) }
                lines.append(matched ? "  （上限で省いた）" : "  （記録なし）")
            }
            for (entry, at) in rows[index] {
                lines.append("  " + pad("+\(Int(at.rounded()))ms", 9, right: true) + " " + pad("\(Int(entry.duration.rounded()))ms", 7, right: true)
                    + " " + pad(byteCount(entry), 7, right: true) + "  " + pad(entry.type, 13) + " " + clip(entry.url, 300))
            }
        }
        if omitted > 0 { lines.append("… ほか \(omitted) 件を省略（requests --limit <数> で増やせる）") }

        let missing = frames.flatMap { frame in frame.missing.filter { filter.matches(type: $0.type, url: $0.url) }.map { (frame.name, $0) } }
        lines.append("")
        if missing.isEmpty {
            lines.append("not loaded: なし")
        } else {
            lines.append("not loaded（要素が指しているのに読み込んだ記録がないもの。広告ブロックで止められたか、つながらなかったか、まだ読み込み中）:")
            let width = missing.map(\.0.count).max() ?? 0
            for (name, item) in missing {
                lines.append("  " + pad(name, width) + "  " + pad(item.type, 6) + " " + clip(item.url, 300) + (item.hint.isEmpty ? "" : " — " + item.hint))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ frames: [FrameRequests], tab: Tab, filter: Filter, limit: Int) throws -> String {
        let (rows, omitted) = select(frames, filter: filter, limit: limit)
        let tenth = { (value: Double) in (value * 10).rounded() / 10 }
        let output: [String: Any] = [
            "tab": tab.number,
            "omitted": omitted,
            "frames": frames.enumerated().map { index, frame -> [String: Any] in
                var object: [String: Any] = ["frame": frame.name, "url": frame.url]
                if !frame.element.isEmpty { object["element"] = frame.element }
                if let error = frame.error {
                    object["error"] = error
                    return object
                }
                object["bufferFull"] = frame.bufferFull
                object["requests"] = rows[index].map { entry, at -> [String: Any] in
                    [
                        "type": entry.type, "url": entry.url, "start": tenth(at), "duration": tenth(entry.duration),
                        "transferSize": Int(entry.transfer), "encodedBodySize": Int(entry.encoded),
                        "decodedBodySize": Int(entry.decoded), "protocol": entry.transport,
                    ]
                }
                object["notLoaded"] = frame.missing.filter { filter.matches(type: $0.type, url: $0.url) }.map {
                    ["type": $0.type, "url": $0.url, "hint": $0.hint]
                }
                return object
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// 運んだ大きさ。0 でも本体の大きさが分かればキャッシュから読んだもの。どちらも 0 なら分からない
    /// （別のオリジンで Timing-Allow-Origin がないもの、メモリのキャッシュから読んだものなど）。
    private static func byteCount(_ entry: RequestEntry) -> String {
        if entry.transfer > 0 { return bytes(entry.transfer) }
        if entry.encoded > 0 { return "cache" }
        return "-"
    }

    private static func bytes(_ value: Double) -> String {
        if value < 1024 { return "\(Int(value))B" }
        if value < 1024 * 1024 { return String(format: "%.1fKB", value / 1024) }
        return String(format: "%.1fMB", value / 1024 / 1024)
    }

    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        guard text.count < width else { return text }
        let space = String(repeating: " ", count: width - text.count)
        return right ? space + text : text + space
    }

    private static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? text.prefix(length - 1) + "…" : text
    }
}
