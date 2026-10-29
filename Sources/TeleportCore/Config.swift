import Foundation
import Security

/// Shared settings, stored in `~/.teleport/config.json`.
///
/// The host creates this file on first launch. Copy it to the viewer Mac so both
/// sides share the LiveKit API key and secret (pairing replaces this later).
public struct TeleportConfig: Codable {
    public var apiKey: String
    public var apiSecret: String
    public var room: String
    /// LiveKit signalling port; RTC uses `port + 1` (TCP) and `port + 2` (UDP).
    public var port: Int
    /// Bundle IDs the host may share. Empty means every app.
    public var allowedApps: [String]
    public var virtualDisplay: VirtualDisplayConfig
    /// Optional explicit path to `livekit-server`.
    public var livekitServerPath: String?

    public struct VirtualDisplayConfig: Codable {
        public var enabled: Bool
        /// Size in points; the pixel size is twice this when `hiDPI` is on.
        public var width: Int
        public var height: Int
        public var hiDPI: Bool
    }

    public static let defaultAllowedApps = [
        "com.microsoft.VSCode",
        "dev.switchboard.app", // Seshboard
        "com.microsoft.edgemac",
        "com.google.Chrome",
        "com.apple.Terminal",
        "com.mitchellh.ghostty",
    ]

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".teleport", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }

    public static func load() throws -> TeleportConfig {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(TeleportConfig.self, from: data)
    }

    /// Loads the config, creating one with fresh credentials when none exists.
    public static func loadOrCreate() throws -> TeleportConfig {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try load()
        }
        let config = TeleportConfig(
            apiKey: "teleport-" + randomHex(bytes: 6),
            apiSecret: randomHex(bytes: 32),
            room: "teleport",
            port: 7880,
            allowedApps: defaultAllowedApps,
            virtualDisplay: .init(enabled: true, width: 1920, height: 1200, hiDPI: true),
            livekitServerPath: nil
        )
        try config.save()
        return config
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    static func randomHex(bytes: Int) -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
