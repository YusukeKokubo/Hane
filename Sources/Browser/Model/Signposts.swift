import os

/// Instruments（`xctrace`）の Points of Interest に出す区間の印。
///
/// 計測していないときはほとんど何もしないので、普段使いでも外さない。
/// 時間の掛かる処理がいつ起きたかを、CPUの記録と重ねて見るためのもの。
enum Signposts {
    static let poster = OSSignposter(subsystem: "local.personal.browser", category: .pointsOfInterest)

    /// 同期の処理を区間で囲む。
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = poster.beginInterval(name)
        defer { poster.endInterval(name, state) }
        return try body()
    }
}
