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

    let launcher = Process()
    launcher.executableURL = URL(filePath: "/usr/bin/open")
    // 普段使い以外のプロファイルは、起動済みの実体とは別にもう一つ立ち上げる。
    // バンドルIDで頼むと Launch Services は ~/Applications に入れてある版を選ぶので、
    // 隣に作り直したアプリがあればそちらを起こす。でないと古い版を確かめたり測ったりしてしまう。
    if BrowserProfile.isDefault {
        launcher.arguments = ["-b", ControlSocket.bundleIdentifier]
    } else {
        let target = siblingApp().map { ["-n", $0] } ?? ["-n", "-b", ControlSocket.bundleIdentifier]
        launcher.arguments = target + ["--env", "\(BrowserProfile.environmentKey)=\(BrowserProfile.name)"]
    }
    launcher.standardError = FileHandle.nullDevice
    try? launcher.run()
    launcher.waitUntilExit()
    guard launcher.terminationStatus == 0 else {
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
