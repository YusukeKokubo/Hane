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

/// 実行ファイルを直に、このコマンドとは別のセッションで起こす。環境変数（プロファイル）はそのまま引き継ぐ。
///
/// `open` で頼むと前に出て、確かめるたびに持ち主の作業を遮る。`open -g` で裏に起こすと SwiftUI が窓を作らない。
/// 直に起こせば窓は出て、前には出ない。別のセッションにするのは、呼んだシェルが閉じても巻き添えで止まらないため。
func spawnDetached(_ executable: String) -> Bool {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    // 起こしたアプリを、端末ではなく自分自身の責任にする。そうしないと端末から起こした実体どうしで
    // WebKit の補助プロセスの持ち主が同じ端末になり、stats が別の実体のプロセスまで数えてしまう。
    // 関数は公開されていないので実行時に探し、なければそのまま起こす。
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
        let disclaim = unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self)
        _ = disclaim(&attributes, 1)
    }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    return posix_spawn(&pid, executable, &actions, &attributes, argv, environ) == 0
}

/// アプリに接続する。起動していなければ起動して、待ち受けが始まるまで待つ。
func connectLaunchingIfNeeded() -> Int32 {
    if let fd = ControlSocket.connect(to: ControlSocket.path) { return fd }

    // 普段使い以外のプロファイルは、起動済みの実体とは別にもう一つ立ち上げる。
    // バンドルIDで頼むと Launch Services は ~/Applications に入れてある版を選ぶので、
    // 隣に作り直したアプリがあればそちらを起こす。でないと古い版を確かめたり測ったりしてしまう。
    // BROWSER_LAUNCH=front なら前に出して起こす。bench.sh が、前面での計測を前の結果と比べられるよう使う。
    let front = ProcessInfo.processInfo.environment["BROWSER_LAUNCH"] == "front"
    let launched: Bool
    if !BrowserProfile.isDefault, !front, let app = siblingApp() {
        launched = spawnDetached(app + "/Contents/MacOS/Browser")
    } else {
        let launcher = Process()
        launcher.executableURL = URL(filePath: "/usr/bin/open")
        let target = BrowserProfile.isDefault
            ? ["-b", ControlSocket.bundleIdentifier]
            : siblingApp().map { ["-n", $0] } ?? ["-n", "-b", ControlSocket.bundleIdentifier]
        launcher.arguments = target
            + (BrowserProfile.isDefault ? [] : ["--env", "\(BrowserProfile.environmentKey)=\(BrowserProfile.name)"])
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
