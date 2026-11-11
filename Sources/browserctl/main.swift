import ControlWire
import Foundation

// 起動中の Browser に命令を1つ送り、結果を表示する。命令の説明は `browserctl help`。

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// このコマンドと同じ場所にある Browser.app（`scripts/bundle.sh` が build/ に並べて置く）。
func siblingApp() -> String? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = executable.deletingLastPathComponent().appending(path: "Browser.app")
    let path = app.path(percentEncoded: false)
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

/// アプリに接続する。起動していなければ起動して、待ち受けが始まるまで待つ。
func connectLaunchingIfNeeded() -> Int32 {
    if let fd = ControlSocket.connect(to: ControlSocket.path) { return fd }

    // 使い捨てのプロファイル（dev など）は、隣に作り直したアプリを起こす。バンドルIDで頼むと
    // Launch Services は ~/Applications に入れてある版を選ぶので、古い版を確かめたり測ったりしてしまう。
    // 保存するプロファイルは持ち主の普段使いなので、入れてある版を起こす。別のプロファイルの実体が
    // 動いていると、-n を付けなければそちらを前に出すだけで終わる。
    // BROWSER_LAUNCH=front なら前に出して起こす。bench.sh が、前面での計測を前の結果と比べられるよう使う。
    let front = ProcessInfo.processInfo.environment["BROWSER_LAUNCH"] == "front"
    let launched: Bool
    if !BrowserProfile.isPersistent, !front, let app = siblingApp() {
        launched = spawnDetached(app + "/Contents/MacOS/Browser")
    } else {
        let launcher = Process()
        launcher.executableURL = URL(filePath: "/usr/bin/open")
        let target = !BrowserProfile.isPersistent
            ? siblingApp().map { ["-n", $0] } ?? ["-n", "-b", ControlSocket.bundleIdentifier]
            : ["-n", "-b", ControlSocket.bundleIdentifier]
        launcher.arguments = target + ["--env", "\(BrowserProfile.environmentKey)=\(BrowserProfile.name)"]
            + (BrowserProfile.isPersistent ? [] : ["--env", "\(BrowserProfile.ephemeralKey)=1"])
        launcher.standardError = FileHandle.nullDevice
        try? launcher.run()
        launcher.waitUntilExit()
        launched = launcher.terminationStatus == 0
    }
    guard launched else {
        fail("Browser が起動しておらず、自動起動もできなかった。build/Browser.app を一度開いておくこと。")
    }
    for _ in 0..<100 {
        if let fd = ControlSocket.connect(to: ControlSocket.path) { return fd }
        usleep(100_000)
    }
    fail("Browser を起動したが、操作用ソケットに接続できなかった。")
}

let arguments = Array(CommandLine.arguments.dropFirst())

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

guard let request = try? JSONEncoder().encode(ControlRequest(args: arguments)) else {
    fail("要求を組み立てられなかった。")
}
ControlSocket.writeMessage(request, to: fd)

guard let reply = ControlSocket.readMessage(from: fd),
      let response = try? JSONDecoder().decode(ControlResponse.self, from: reply)
else {
    fail("Browser から応答がなかった。")
}
close(fd)

if response.ok {
    print(response.output)
} else {
    fail(response.output)
}
