// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS("26.7")],
    targets: [
        // アプリ本体。
        .executableTarget(
            name: "Browser",
            dependencies: ["ControlWire"],
            path: "Sources/Browser"
        ),
        // 外部（LLMエージェントなど）からアプリを操作するコマンド。
        .executableTarget(
            name: "browserctl",
            dependencies: ["ControlWire"],
            path: "Sources/browserctl"
        ),
        // アプリとコマンドが共有する通信の取り決め。
        .target(
            name: "ControlWire",
            path: "Sources/ControlWire"
        ),
        .testTarget(
            name: "BrowserTests",
            dependencies: ["Browser"],
            path: "Tests/BrowserTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
