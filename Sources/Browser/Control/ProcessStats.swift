import Darwin
import Foundation

/// このアプリと、その下で動くWebKitの補助プロセスのメモリ・CPU・起床回数を測る。開発時の計測用。
enum ProcessStats {
    struct Sample {
        let pid: pid_t
        let name: String
        /// 実メモリの使用量（アクティビティモニタの「メモリ」と同じ指標）。
        let footprint: UInt64
        /// 起動からの累積CPU時間（ナノ秒）。
        let cpuTime: UInt64
        /// 起動からの累積の起床回数。タイマーや割り込みでスレッドが起こされた回数で、
        /// 何もしていないはずのときに増えていれば、どこかで常に何かが動いている。
        let wakeups: UInt64
    }

    /// 測定の期間に対する1プロセスぶんの結果。
    struct Row: Codable {
        let name: String
        let pid: Int32?
        let memoryBytes: UInt64
        let cpuPercent: Double
        let wakeupsPerSecond: Double
    }

    struct Report: Codable {
        /// 測っている実行ファイル。入れてある版と作り直した版を取り違えないため。
        let executable: String
        let seconds: Double
        let processes: [Row]
        let total: Row
        /// 補助プロセスを特定できず、アプリ本体だけを測ったか。
        let appOnly: Bool
    }

    /// 期間をおいて2回測り、その間のCPU使用率と起床回数を出す。
    static func measure(for interval: Duration = .milliseconds(500)) async -> Report {
        let pids = family()
        let before = Dictionary(uniqueKeysWithValues: pids.compactMap(sample).map { ($0.pid, $0) })
        let clock = ContinuousClock()
        let start = clock.now
        try? await Task.sleep(for: interval)
        let duration = clock.now - start
        let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let after = pids.compactMap(sample)

        var rows: [Row] = []
        for current in after.sorted(by: { $0.footprint > $1.footprint }) {
            let previous = before[current.pid]
            let cpu = Double(current.cpuTime &- (previous?.cpuTime ?? current.cpuTime)) / 1e9
            let wakeups = Double(current.wakeups &- (previous?.wakeups ?? current.wakeups))
            rows.append(Row(
                name: current.pid == getpid() ? "Browser (app)" : current.name,
                pid: current.pid,
                memoryBytes: current.footprint,
                cpuPercent: elapsed > 0 ? cpu / elapsed * 100 : 0,
                wakeupsPerSecond: elapsed > 0 ? wakeups / elapsed : 0
            ))
        }
        let total = Row(
            name: "total (\(rows.count) processes)", pid: nil,
            memoryBytes: rows.reduce(0) { $0 + $1.memoryBytes },
            cpuPercent: rows.reduce(0) { $0 + $1.cpuPercent },
            wakeupsPerSecond: rows.reduce(0) { $0 + $1.wakeupsPerSecond }
        )
        return Report(
            executable: Bundle.main.executableURL?.path(percentEncoded: false) ?? CommandLine.arguments[0],
            seconds: elapsed, processes: rows, total: total, appOnly: responsiblePID == nil
        )
    }

    /// 人が読む表にする。
    static func table(_ report: Report) -> String {
        var lines = ["process".padding(toLength: 34, withPad: " ", startingAt: 0)
            + "    pid     memory    cpu  wakeups/s"]
        lines += report.processes.map(row)
        lines.append(row(report.total))
        lines.append(String(format: "（%.1f 秒間の平均。実行ファイル: %@）", report.seconds, report.executable))
        if report.appOnly {
            lines.append("（補助プロセスを特定できなかったため、アプリ本体のみ）")
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ row: Row) -> String {
        let pid = row.pid.map(String.init) ?? ""
        return row.name.padding(toLength: 34, withPad: " ", startingAt: 0)
            + String(repeating: " ", count: max(0, 7 - pid.count)) + pid
            + String(format: " %7.1f MB %5.1f%% %10.1f", Double(row.memoryBytes) / 1_048_576, row.cpuPercent, row.wakeupsPerSecond)
    }

    /// 自分自身と、自分と同じ「責任プロセス」に属するWebKitの補助プロセス
    /// （WebContent、Networking、GPU）。
    ///
    /// Finderから起動すれば責任プロセスは自分自身、端末から直接起動すれば端末になるので、
    /// 自分の責任プロセスと比べたうえで、名前でWebKitのものに絞る。
    private static func family() -> [pid_t] {
        let me = getpid()
        guard let responsiblePID else { return [me] }
        let owner = responsiblePID(me)

        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, count)).filter { pid in
            pid == me || (pid > 0 && responsiblePID(pid) == owner && name(of: pid).hasPrefix("com.apple.WebKit."))
        }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = Int(proc_name(pid, &buffer, UInt32(buffer.count)))
        return String(decoding: buffer.prefix(max(0, length)), as: UTF8.self)
    }

    private static func sample(_ pid: pid_t) -> Sample? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }

        let name = name(of: pid)

        let ticks = usage.ri_user_time + usage.ri_system_time
        return Sample(pid: pid, name: name.isEmpty ? "pid \(pid)" : name,
                      footprint: usage.ri_phys_footprint,
                      cpuTime: ticks * UInt64(timebase.numer) / UInt64(timebase.denom),
                      wakeups: usage.ri_interrupt_wkups)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// 補助プロセスがどのアプリのものかを調べる関数。公開APIにはないので、実行時に探す。
    /// 見つからなければ本体だけを測る。
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()
}
