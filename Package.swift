// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SilkMouse",
    platforms: [.macOS(.v15)], // macOS 15+ only — lets us use modern APIs and drop legacy compat
    targets: [
        .executableTarget(
            name: "SilkMouse",
            path: "Sources/SilkMouse",
            swiftSettings: [
                // v1 uses Swift 5 language mode: the CGEventTap C-callback bridging is simpler
                // without Swift 6 strict-concurrency ceremony. Tighten to .v6 once the engine is stable.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SilkMouseTests",
            dependencies: ["SilkMouse"],
            path: "Tests/SilkMouseTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
