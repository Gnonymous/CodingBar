// swift-tools-version: 6.0
import PackageDescription

// CodingBar — a lightweight macOS menu bar app that visualizes local AI coding agent usage.
// Pure SwiftPM (no Xcode project). Language mode v5 to keep concurrency pragmatic for v1.
let package = Package(
    name: "CodingBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle powers in-app auto-update (EdDSA-signed appcast → silent install).
        // Pinned to a 2.x range so we follow patch fixes without breaking changes.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.8.1"),
    ],
    targets: [
        .target(
            name: "CodingBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CodingBar",
            dependencies: [
                "CodingBarCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CodingBarCoreTests",
            dependencies: ["CodingBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
