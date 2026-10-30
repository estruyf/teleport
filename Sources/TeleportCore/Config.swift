import Foundation
import Security

/// Settings for this Mac, stored in `~/.teleport/config.json`.
///
/// Nothing in here is copied between Macs. The LiveKit key and secret are the host's own;
/// viewers get short-lived tokens from the host after pairing.
public struct TeleportConfig: Codable {
    public enum Mode: String, Codable, CaseIterable {
        case host, viewer
    }

    /// Nil until the first launch asks.
    public var mode: Mode?
    /// Shown to the other Mac when pairing.
    public var deviceName: String
    public var apiKey: String
    public var apiSecret: String
    public var room: String
    /// LiveKit signalling port; RTC uses `port + 1` (TCP) and `port + 2` (UDP), control `port + 3`.
    public var port: Int
    /// Bundle IDs the host may share. Nothing is shared until an app is added.
    public var allowedApps: [String]
    public var virtualDisplay: VirtualDisplayConfig
    /// Optional explicit path to `livekit-server`.
    public var livekitServerPath: String?
    /// Share clipboard text with the other Mac. Nil means on.
    public var clipboardSync: Bool?
    /// Play a short sound when a portal opens or a Mac pairs. Nil means off.
    public var sounds: Bool?

    public var clipboardSyncEnabled: Bool { clipboardSync ?? true }
    public var soundsEnabled: Bool { sounds ?? false }

    public struct VirtualDisplayConfig: Codable {
        public var enabled: Bool
        /// Size in points; the pixel size is twice this when `hiDPI` is on.
        public var width: Int
        public var height: Int
        public var hiDPI: Bool
        public init(enabled: Bool, width: Int, height: Int, hiDPI: Bool) {
            self.enabled = enabled
            self.width = width
            self.height = height
            self.hiDPI = hiDPI
        }
    }


    /// `TELEPORT_HOME` points a second instance at its own identity and settings (for a loopback test).
    public static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["TELEPORT_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".teleport", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }

    public static func load() throws -> TeleportConfig {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(TeleportConfig.self, from: data)
    }

    /// Loads the config, creating one with fresh credentials when none exists.
    public static func loadOrCreate() -> TeleportConfig {
        if let existing = try? load() { return existing }
        let config = TeleportConfig(
            mode: nil,
            deviceName: Host.current().localizedName ?? "Mac",
            apiKey: "teleport-" + randomHex(bytes: 6),
            apiSecret: randomHex(bytes: 32),
            room: "teleport",
            port: 7880,
            allowedApps: [],
            virtualDisplay: .init(enabled: true, width: 1920, height: 1200, hiDPI: true),
            livekitServerPath: nil,
            clipboardSync: nil,
            sounds: nil
        )
        try? config.save()
        return config
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    public var controlPort: Int { port + 3 }

    static func randomHex(bytes: Int) -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
        return data.map { String(format: "%02x", $0) }.joined()
    }

    public static func randomNonce() -> String { randomHex(bytes: 16) }
}

public enum TeleportVersion {
    public static let string = "0.2.0"
}
