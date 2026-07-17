// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mousse",
    platforms: [.macOS(.v14)], // macOS 14+ — supports Sonoma and newer
    targets: [
        .executableTarget(
            name: "Mousse",
            path: "Sources/Mousse",
            swiftSettings: [
                // v1 uses Swift 5 language mode: the CGEventTap C-callback bridging is simpler
                // without Swift 6 strict-concurrency ceremony. Tighten to .v6 once the engine is stable.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MousseTests",
            dependencies: ["Mousse"],
            path: "Tests/MousseTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
