// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexTokenOverlayMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CodexTokenCore",
            targets: ["CodexTokenCore"]
        ),
        .executable(
            name: "CodexTokenOverlayMac",
            targets: ["CodexTokenOverlayMac"]
        )
    ],
    targets: [
        .target(
            name: "CodexTokenCore"
        ),
        .executableTarget(
            name: "CodexTokenOverlayMac",
            dependencies: ["CodexTokenCore"]
        ),
        .testTarget(
            name: "CodexTokenCoreTests",
            dependencies: ["CodexTokenCore"]
        )
    ]
)
