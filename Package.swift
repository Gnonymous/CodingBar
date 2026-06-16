// swift-tools-version: 6.0
import PackageDescription

// CodingBar — a lightweight macOS menu bar app that visualizes local AI coding agent usage.
// Pure SwiftPM (no Xcode project). Language mode v5 to keep concurrency pragmatic for v1.
let package = Package(
    name: "CodingBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CodingBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CodingBar",
            dependencies: ["CodingBarCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CodingBarCoreTests",
            dependencies: ["CodingBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
