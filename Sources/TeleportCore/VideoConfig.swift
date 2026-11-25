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
    public enum Encoder: String, Codable, Sendable {
        /// The SDK's VideoToolbox encoder.
        case webrtc
        /// Teleport's own VideoToolbox session, which can paint over.
        case teleport
    }

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
    /// Host: which encoder makes the stream. Read at launch. `paintOver` implies `teleport`.
    public var encoder: Encoder?
    /// Host: once the window stops moving, send a few frames at a QP ceiling and a raised bitrate.
    public var paintOver: Bool?
    /// Host: stillness before a paint-over, in ms.
    public var paintOverDelayMs: Int?
    /// Host: frames in a paint-over.
    public var paintOverFrames: Int?
    /// Host: QP ceiling for paint-over frames (0–51; lower is sharper and bigger).
    public var paintOverMaxQP: Int?
    /// Host: bitrate for paint-over frames, as a multiple of WebRTC's target.
    public var paintOverBitrateBoost: Double?
    /// Host: share of the window (0–1) that must change for a frame to count as motion.
    public var motionMinArea: Double?
    /// Host, teleport encoder: ask VideoToolbox for speed over quality.
    public var prioritizeSpeed: Bool?

    /// Keys this section had that Teleport didn't understand; reported once at startup.
    public private(set) var problems: [String] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case stats, codec, degradation, maxBitrateKbps, playoutDelayMs, encoder
        case paintOver, paintOverDelayMs, paintOverFrames, paintOverMaxQP, paintOverBitrateBoost
        case motionMinArea, prioritizeSpeed
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
        encoder = field(.encoder)
        paintOver = field(.paintOver)
        paintOverDelayMs = field(.paintOverDelayMs)
        paintOverFrames = field(.paintOverFrames)
        paintOverMaxQP = field(.paintOverMaxQP)
        paintOverBitrateBoost = field(.paintOverBitrateBoost)
        motionMinArea = field(.motionMinArea)
        prioritizeSpeed = field(.prioritizeSpeed)
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
    public var encoder: VideoConfig.Encoder
    public var paintOver: Bool
    public var paintOverDelayMs: Int
    public var paintOverFrames: Int
    public var paintOverMaxQP: Int
    public var paintOverBitrateBoost: Double
    public var motionMinArea: Double
    public var prioritizeSpeed: Bool
    public var problems: [String]

    public init(_ config: VideoConfig) {
        stats = config.stats ?? false
        codec = config.codec ?? .h264
        degradation = config.degradation ?? .maintainResolution
        maxBitrateKbps = min(max(config.maxBitrateKbps ?? 25000, 500), 200_000)
        // The RTP header extension carries up to 40.95 s; more than a few seconds is never wanted here.
        playoutDelayMs = config.playoutDelayMs.map { min(max($0, 0), 10000) }
        paintOver = config.paintOver ?? false
        encoder = paintOver ? .teleport : (config.encoder ?? .webrtc)
        paintOverDelayMs = min(max(config.paintOverDelayMs ?? 150, 30), 5000)
        paintOverFrames = min(max(config.paintOverFrames ?? 3, 1), 10)
        paintOverMaxQP = min(max(config.paintOverMaxQP ?? 22, 1), 51)
        paintOverBitrateBoost = min(max(config.paintOverBitrateBoost ?? 4, 1), 20)
        // A caret is a few thousandths of a percent of a window, a spinner well under 0.1%.
        motionMinArea = min(max(config.motionMinArea ?? 0.01, 0), 1)
        prioritizeSpeed = config.prioritizeSpeed ?? true
        problems = config.problems
        if config.paintOver == true, config.encoder == .webrtc {
            problems.append("video.paintOver needs encoder teleport; using it")
        }
    }

    /// One line for the log, so stats.log lines can be matched to the settings they ran with.
    public var description: String {
        [
            "stats=\(stats)", "codec=\(codec.rawValue)", "degradation=\(degradation.rawValue)",
            "maxBitrateKbps=\(maxBitrateKbps)", "playoutDelayMs=\(playoutDelayMs.map(String.init) ?? "unset")",
            "encoder=\(encoder.rawValue)\(encoder == .teleport ? " prioritizeSpeed=\(prioritizeSpeed)" : "")",
            paintOver ? "paintOver delay=\(paintOverDelayMs)ms frames=\(paintOverFrames) maxQP=\(paintOverMaxQP) boost=\(paintOverBitrateBoost)x motionMinArea=\(motionMinArea)" : "paintOver=false",
        ].joined(separator: " ")
    }
}
