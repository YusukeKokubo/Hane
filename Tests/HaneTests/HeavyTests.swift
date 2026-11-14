import Foundation

/// 重くて、限られた場所を変えたときにしか結果が変わらないテストを、普段は飛ばすための切り替え。
///
/// 使うテストは `.enabled(if: HeavyTests.enabled, "…")` を付け、理由の文に「何を変えたら回すか」と回し方を書く。
/// 飛ばした行は `swift test` の出力に理由つきで出るので、触った場所と見比べて回すかどうかを決められる。
/// `HANE_HEAVY_TESTS=1` を付けると回る（`verify.sh` と `update-filters.sh` は付けて回す）。
enum HeavyTests {
    static let enabled = ProcessInfo.processInfo.environment["HANE_HEAVY_TESTS"] != nil
}
