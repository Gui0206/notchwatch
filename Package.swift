// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchAIControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchAIControl",
            path: "Sources/NotchAIControl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "notch-hook",
            path: "Sources/notch-hook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
