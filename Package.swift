// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Teleport",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.19.0"),
    ],
    targets: [
        // Declarations for the private macOS APIs we use (CGVirtualDisplay, _AXUIElementGetWindow).
        .target(name: "CPrivate", linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("ApplicationServices")]),
        // Config, identity, pairing crypto, wire protocol: shared by the app and the dock tile.
        .target(name: "TeleportCore"),
        // The app: host or viewer, chosen on first launch.
        .executableTarget(
            name: "Teleport",
            dependencies: ["CPrivate", "TeleportCore", .product(name: "LiveKit", package: "client-sdk-swift")]
        ),
        // One copy of this runs per remote app, so it gets its own badged Dock icon.
        .executableTarget(name: "TeleportDockTile", dependencies: ["TeleportCore"]),
        .testTarget(name: "TeleportCoreTests", dependencies: ["TeleportCore"]),
    ]
)
