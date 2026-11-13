import ControlWire
import Foundation

// 起動中の Hane に命令を1つ送り、結果を表示する。命令の説明は `hanectl help`。

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// このコマンドと同じ場所にある Hane.app（`scripts/bundle.sh` が build/ に並べて置く）。
func siblingApp() -> String? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = executable.deletingLastPathComponent().appending(path: "Hane.app")
    let path = app.path(percentEncoded: false)
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

func runOpen(_ arguments: [String]) -> Bool {
    let launcher = Process()
    launcher.executableURL = URL(filePath: "/usr/bin/open")
    launcher.arguments = arguments
    launcher.standardError = FileHandle.nullDevice
    guard (try? launcher.run()) != nil else { return false }
    launcher.waitUntilExit()
    return launcher.terminationStatus == 0
}

/// アプリに接続する。起動していなければ起動して、待ち受けが始まるまで待つ。
func connectLaunchingIfNeeded() -> Int32 {
    if let fd = ControlSocket.connect(to: ControlSocket.path) { return fd }

    // 使い捨ての実体（dev など）は、隣に作り直したアプリを起こす。バンドルIDで頼むと
    // Launch Services は ~/Applications に入れてある版を選ぶので、古い版を確かめたり測ったりしてしまう。
    // 普段使いの実体は入れてある版を起こす。-n を付けないと、使い捨ての実体が動いているときにそちらを前に出すだけで終わる。
    // HANE_LAUNCH=front なら前に出して起こす。bench.sh が、前面での計測を前の結果と比べられるよう使う。
    // open は環境変数を引き継がないので、実体の名前は --env で渡す。
    let front = ProcessInfo.processInfo.environment["HANE_LAUNCH"] == "front"
    let launched: Bool
    if let instance = BrowserInstance.name {
        if !front, let app = siblingApp() {
            launched = spawnDetached(app + "/Contents/MacOS/Hane")
        } else {
            let target = siblingApp().map { ["-n", $0] } ?? ["-n", "-b", ControlSocket.bundleIdentifier]
            launched = runOpen(target + ["--env", "\(BrowserInstance.environmentKey)=\(instance)"])
        }
    } else {
        launched = runOpen(["-n", "-b", ControlSocket.bundleIdentifier])
    }
    guard launched else {
        fail("Hane が起動しておらず、自動起動もできなかった。build/Hane.app を一度開いておくこと。")
    }
    for _ in 0..<100 {
        if let fd = ControlSocket.connect(to: ControlSocket.path) { return fd }
        usleep(100_000)
    }
    fail("Hane を起動したが、操作用ソケットに接続できなかった。")
}

let arguments = Array(CommandLine.arguments.dropFirst())

// 前の書き方のまま呼ばれたら、黙って普段使いの実体を操作せずに止める。
if let problem = BrowserInstance.startupProblem {
    fail(problem)
}

// 使い方を見るだけなら、アプリを起動しない。
if arguments.isEmpty || ["help", "--help", "-h"].contains(arguments[0]) {
    print(ControlHelp.text)
    exit(0)
}

// 止めるだけなら、起動していないときに起こさない。起こしてすぐ止めると、作り直している最中の古い版が動き出すことがある。
if arguments == ["quit"] {
    guard let probe = ControlSocket.connect(to: ControlSocket.path) else {
        print("起動していない")
        exit(0)
    }
    close(probe)
}

let fd = connectLaunchingIfNeeded()
ControlSocket.ignoreBrokenPipe(fd)
ControlSocket.limitWaiting(fd)

guard let request = try? JSONEncoder().encode(ControlRequest(args: arguments)) else {
    fail("要求を組み立てられなかった。")
}
ControlSocket.writeMessage(request, to: fd)

let reply = ControlSocket.readMessage(from: fd)
if reply == nil, errno == EAGAIN {
    fail("Hane が \(ControlSocket.replyTimeout) 秒待っても答えなかった。止まっているか、別の実体がソケットを握っている。"
        + "`lsof -U | grep control.sock` で持ち主を、`sample <pid> 1` で止まっている所を見ること。")
}
guard let reply, let response = try? JSONDecoder().decode(ControlResponse.self, from: reply) else {
    fail("Hane から応答がなかった。")
}
close(fd)

if response.ok {
    print(response.output)
} else {
    fail(response.output)
}
