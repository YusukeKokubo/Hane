// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS("26.7")],
    targets: [
        .executableTarget(
            name: "Browser",
            path: "Sources/Browser"
        ),
        .testTarget(
            name: "BrowserTests",
            dependencies: ["Browser"],
            path: "Tests/BrowserTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
