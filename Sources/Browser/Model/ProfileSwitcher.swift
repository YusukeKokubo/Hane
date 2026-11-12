import AppKit
import ControlWire
import Foundation
import Observation

/// プロファイルの一覧と切り替え。
///
/// 一つの実体は一つのプロファイルだけを受け持つので、切り替えはそのプロファイルの実体を起こすか、
/// 起動済みのものを前に出すことになる。一つの窓の中で入れ替える形にしなかったのは、切り替えるたびに
/// 全部のタブを読み込み直すことになり、仕事用と私用を並べても使えないため。開いていないプロファイルは
/// プロセスごとないので、何も食わない。
@MainActor
@Observable
final class ProfileSwitcher {
    /// この実体のプロファイル。
    let current: String
    /// メニューに並べる順。保存する実体では普段使いが先頭で、続いて登録した順。
    private(set) var names: [String]
    /// 新しいプロファイルの名前を尋ねているか。
    var isCreating = false
    /// 利用者に見せる失敗。
    var failure: String?

    /// 一覧の置き場。使い捨ての実体では `nil` で、作った名前はこの実体の中にだけ持つ。
    @ObservationIgnored private let registryURL: URL?
    @ObservationIgnored private var temporaryNames: [String] = []

    init(current: String = BrowserProfile.name, registryURL: URL?) {
        self.current = current
        self.registryURL = registryURL
        names = []
        reload()
    }

    /// 使い捨ての実体には登録した一覧を見せない。そこから普段使いの実体を起こしたり、一覧を書き換えたりしないため。
    static func forCurrentProfile() -> ProfileSwitcher {
        ProfileSwitcher(registryURL: BrowserProfile.isPersistent ? ProfileRegistry.fileURL : nil)
    }

    var isPersistent: Bool { registryURL != nil }

    static func title(for name: String) -> String {
        name == BrowserProfile.defaultName ? "標準" : name
    }

    /// 一覧を読み直す。別の実体で足したプロファイルを拾うため、アプリが前に出るたびに呼ぶ。
    func reload() {
        let fresh: [String]
        if let registryURL {
            let registered = (try? ProfileRegistry.load(from: registryURL))?.profiles.map(\.name) ?? []
            fresh = [BrowserProfile.defaultName] + registered
        } else {
            fresh = [current] + temporaryNames
        }
        // 同じ中身で書き換えると、メニューを作り直させてしまう。
        if fresh != names { names = fresh }
    }

    /// プロファイルを作って一覧に足す。開くのは別（`open`）。
    func create(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let registryURL {
            // 別の実体が足したばかりの分を消さないよう、書く直前に読み直す。
            var registry = try ProfileRegistry.load(from: registryURL)
            try registry.add(name)
            try registry.save(to: registryURL)
        } else {
            if let problem = BrowserProfile.problem(withName: name) { throw ProfileError("使えない名前: \(problem)") }
            guard !names.contains(name) else { throw ProfileError("「\(name)」はもうある") }
            temporaryNames.append(name)
        }
        reload()
        return name
    }

    /// メニューやシートから。失敗はアラートで見せる。
    func createAndOpen(_ rawName: String) {
        do {
            open(try create(rawName))
        } catch {
            failure = String(describing: error)
        }
    }

    /// メニューから。失敗はアラートで見せる。
    func open(_ name: String) {
        Task {
            do {
                _ = try await switchTo(name)
            } catch {
                failure = String(describing: error)
            }
        }
    }

    enum Outcome: Equatable {
        case alreadyHere
        /// 起動済みの実体を前に出した（使い捨ての実体からは出さない）。
        case activated(pid: Int32)
        case launched(pid: Int32)
    }

    /// プロファイルの実体へ移る。起動していなければ起こし、操作用ソケットで答えるまで待つ。
    ///
    /// 保存する実体からは前に出して起こす。使い捨ての実体（開発用）からは裏に起こし、起動済みでも前に出さない。
    /// 確かめるたびに持ち主の作業を遮らないため。使い捨ての実体から起こした実体も使い捨てにする。
    func switchTo(_ name: String) async throws -> Outcome {
        guard names.contains(name) else { throw ProfileError("「\(name)」というプロファイルはない") }
        guard name != current else {
            if isPersistent { NSApp.activate() }
            return .alreadyHere
        }
        let path = ControlSocket.path(for: name)
        let forward = isPersistent
        let frame = WindowFrameMemory.handOver()
        if forward {
            // 前に出るのは相手の側なので、こちらから譲っておかないと、システムに断られて後ろに留まる。
            // 同じバンドルIDの実体どうしなので、名指しせずに譲れる。
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: ControlSocket.bundleIdentifier)
        }
        if let pid = await Self.pid(at: path, activating: false) {
            if !frame.isEmpty { _ = await Self.send(["window-frame", frame], to: path) }
            if forward {
                _ = await Self.send(["activate"], to: path)
                await hideOnceLeft()
            }
            return .activated(pid: pid)
        }

        let environment = [BrowserProfile.environmentKey: name, WindowFrameMemory.handOverKey: frame]
        if forward {
            // 同じアプリをもう一つ立ち上げるのは Launch Services を通す方法しかないので、ここだけ AppKit を使う。
            // 通さずに直に起こすと、Dock に並ばず前にも出ない。
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.environment = environment
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        } else {
            guard let executable = Bundle.main.executablePath,
                  spawnDetached(executable, environment: environment.merging([BrowserProfile.ephemeralKey: "1"]) { $1 })
            else { throw ProfileError("「\(name)」の実体を起こせなかった") }
        }
        for _ in 0..<100 {
            if let pid = await Self.pid(at: path, activating: false) {
                if forward { await hideOnceLeft() }
                return .launched(pid: pid)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProfileError("「\(name)」の実体を起こしたが、応答がない")
    }

    /// 切り替え先が前に出たのを見届けてから、この実体を隠す。重ねた窓の下から元の窓が覗かないようにするため。
    ///
    /// 前に出る前に隠すと、システムが別のアプリを前に出してしまう。前に出られなかったときは隠さず、元の窓を残す。
    /// 使い捨ての実体は相手を前に出さないので隠さない（持ち主の作業を遮らず、確かめる命令も届くように）。
    private func hideOnceLeft() async {
        for _ in 0..<30 {
            if !NSApp.isActive {
                NSApp.hide(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 起動済みの実体に問い合わせ、そのプロセス番号を返す。`activating` なら前に出させる。起動していなければ `nil`。
    nonisolated static func pid(at path: String, activating: Bool) async -> Int32? {
        guard let response = await send([activating ? "activate" : "pid"], to: path), response.ok else { return nil }
        return Int32(response.output.split(separator: " ").last ?? "")
    }

    /// 別の実体へ命令を送る。ソケットの読み書きで止まるので、メインスレッドの外で待つ。
    nonisolated static func send(_ args: [String], to path: String) async -> ControlResponse? {
        await Task.detached { ControlSocket.send(args, to: path) }.value
    }

    /// 同じプロファイルの実体がもう動いていれば、そちらを前に出して、この実体は起動をやめる。
    ///
    /// 同じプロファイルを二つ動かすと、操作用ソケットを奪い合い、閲覧状態やブックマークを互いに上書きしてしまう。
    nonisolated static func handOffIfAlreadyRunning() {
        guard let response = ControlSocket.send(["pid"], to: ControlSocket.path), response.ok else { return }
        if BrowserProfile.isPersistent {
            _ = ControlSocket.send(["activate"], to: ControlSocket.path)
        }
        exit(0)
    }
}
