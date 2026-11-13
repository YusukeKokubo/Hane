// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hane",
    platforms: [.macOS("26.7")],
    targets: [
        // アプリ本体。
        .executableTarget(
            name: "Hane",
            dependencies: ["ControlWire"],
            path: "Sources/Hane"
        ),
        // 外部（LLMエージェントなど）からアプリを操作するコマンド。
        .executableTarget(
            name: "hanectl",
            dependencies: ["ControlWire"],
            path: "Sources/hanectl"
        ),
        // アプリとコマンドが共有する通信の取り決め。
        .target(
            name: "ControlWire",
            path: "Sources/ControlWire"
        ),
        .testTarget(
            name: "HaneTests",
            dependencies: ["Hane"],
            path: "Tests/HaneTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
