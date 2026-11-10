import Darwin
import Foundation

/// このアプリと、その下で動くWebKitの補助プロセスのメモリとCPUを測る。開発時の計測用。
enum ProcessStats {
    struct Sample {
        let pid: pid_t
        let name: String
        /// 実メモリの使用量（アクティビティモニタの「メモリ」と同じ指標）。
        let footprint: UInt64
        /// 起動からの累積CPU時間（ナノ秒）。
        let cpuTime: UInt64
    }

    /// 短い間隔で2回測り、その間のCPU使用率とあわせて表にする。
    static func report(interval: Duration = .milliseconds(500)) async -> String {
        let pids = family()
        let before = Dictionary(uniqueKeysWithValues: pids.compactMap(sample).map { ($0.pid, $0) })
        let clock = ContinuousClock()
        let start = clock.now
        try? await Task.sleep(for: interval)
        let elapsed = Double((clock.now - start).components.attoseconds) / 1e18
            + Double((clock.now - start).components.seconds)
        let after = pids.compactMap(sample)

        var lines = ["process".padding(toLength: 34, withPad: " ", startingAt: 0) + "    pid     memory    cpu"]
        var totalMemory: UInt64 = 0
        var totalCPU = 0.0
        for current in after.sorted(by: { $0.footprint > $1.footprint }) {
            let used = Double(current.cpuTime &- (before[current.pid]?.cpuTime ?? current.cpuTime)) / 1e9
            let cpu = elapsed > 0 ? used / elapsed * 100 : 0
            totalMemory += current.footprint
            totalCPU += cpu
            lines.append(row(current.pid == getpid() ? "Browser (app)" : current.name,
                             pid: String(current.pid), memory: current.footprint, cpu: cpu))
        }
        lines.append(row("total (\(after.count) processes)", pid: "", memory: totalMemory, cpu: totalCPU))
        if responsiblePID == nil {
            lines.append("（補助プロセスを特定できなかったため、アプリ本体のみ）")
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ name: String, pid: String, memory: UInt64, cpu: Double) -> String {
        let megabytes = String(format: "%7.1f MB", Double(memory) / 1_048_576)
        let percent = String(format: "%5.1f%%", cpu)
        return name.padding(toLength: 34, withPad: " ", startingAt: 0)
            + String(repeating: " ", count: max(0, 7 - pid.count)) + pid + " " + megabytes + " " + percent
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
                      cpuTime: ticks * UInt64(timebase.numer) / UInt64(timebase.denom))
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
