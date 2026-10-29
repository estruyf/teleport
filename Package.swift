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
        .target(name: "TeleportCore"),
        .executableTarget(
            name: "TeleportHost",
            dependencies: ["CPrivate", "TeleportCore", .product(name: "LiveKit", package: "client-sdk-swift")]
        ),
        .executableTarget(
            name: "TeleportViewer",
            dependencies: ["TeleportCore", .product(name: "LiveKit", package: "client-sdk-swift")]
        ),
        // One copy of this runs per remote app, so it gets its own badged Dock icon.
        .executableTarget(name: "TeleportDockTile", dependencies: ["TeleportCore"]),
    ]
)
