import Foundation

/// The `video` section of `config.json`: switches for A/B testing the video path.
///
/// Every key is optional and leaving it out keeps what Teleport did before the key existed.
/// The keys are documented in `docs/video-quality.md`. A value that doesn't parse is dropped
/// with a warning instead of failing the whole config: `loadOrCreate()` would otherwise
/// replace it, and with it this Mac's pairing keys.
public struct VideoConfig: Codable, Equatable, Sendable {
    public enum Codec: String, Codable, Sendable { case h264, h265 }
    public enum Degradation: String, Codable, Sendable { case maintainResolution, maintainFramerateAndResolution }

    /// Both: write a line a second per portal to `stats.log`.
    public var stats: Bool?
    /// Host: codec offered for portals.
    public var codec: Codec?
    /// Host: what WebRTC may give up under CPU or bandwidth pressure.
    public var degradation: Degradation?
    /// Host: ceiling for a portal's bitrate.
    public var maxBitrateKbps: Int?
    /// Host: playout delay viewers are asked to hold, in ms; unset leaves WebRTC's adaptive jitter buffer.
    public var playoutDelayMs: Int?

    /// Keys this section had that Teleport didn't understand; reported once at startup.
    public private(set) var problems: [String] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case stats, codec, degradation, maxBitrateKbps, playoutDelayMs
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var problems: [String] = []
        func field<T: Decodable>(_ key: CodingKeys) -> T? {
            do {
                return try container.decodeIfPresent(T.self, forKey: key)
            } catch {
                problems.append("video.\(key.stringValue) has a value Teleport doesn't understand; using the default")
                return nil
            }
        }
        stats = field(.stats)
        codec = field(.codec)
        degradation = field(.degradation)
        maxBitrateKbps = field(.maxBitrateKbps)
        playoutDelayMs = field(.playoutDelayMs)
        // A typo ("Stats") would otherwise be ignored without a word.
        let all = try decoder.container(keyedBy: AnyKey.self)
        for key in all.allKeys where CodingKeys(stringValue: key.stringValue) == nil {
            problems.append("video.\(key.stringValue) is not a setting Teleport knows")
        }
        self.problems = problems
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }
}

/// `VideoConfig` with the defaults filled in and values kept in range: what the code runs with.
public struct VideoTuning: Equatable, Sendable, CustomStringConvertible {
    public var stats: Bool
    public var codec: VideoConfig.Codec
    public var degradation: VideoConfig.Degradation
    public var maxBitrateKbps: Int
    public var playoutDelayMs: Int?
    public var problems: [String]

    public init(_ config: VideoConfig) {
        stats = config.stats ?? false
        codec = config.codec ?? .h264
        degradation = config.degradation ?? .maintainResolution
        maxBitrateKbps = min(max(config.maxBitrateKbps ?? 25000, 500), 200_000)
        // The RTP header extension carries up to 40.95 s; more than a few seconds is never wanted here.
        playoutDelayMs = config.playoutDelayMs.map { min(max($0, 0), 10000) }
        problems = config.problems
    }

    /// One line for the log, so stats.log lines can be matched to the settings they ran with.
    public var description: String {
        [
            "stats=\(stats)", "codec=\(codec.rawValue)", "degradation=\(degradation.rawValue)",
            "maxBitrateKbps=\(maxBitrateKbps)", "playoutDelayMs=\(playoutDelayMs.map(String.init) ?? "unset")",
        ].joined(separator: " ")
    }
}
