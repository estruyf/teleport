import Foundation
import LiveKit
import TeleportCore

/// `~/.teleport/stats.log`: one line a second per portal track, from WebRTC's own statistics.
/// Every video setting is judged by it (`npm run logs:stats`); see docs/video-quality.md.
enum StatsLog {
    /// Opened on first use, so a Mac with stats off never creates the file.
    static let file = LogFile(name: "stats.log")

    static func write(_ line: String) {
        file.write("\(Log.timestamp()) \(line)\n")
    }
}

/// Turns a track's statistics into a `stats.log` line.
///
/// WebRTC's counters are totals since the stream began, so every value on the line is the
/// difference with the previous report: frames, bytes, QP and timing for this second only.
/// The SDK holds track delegates weakly; whoever creates a reporter keeps it.
final class TrackStatsReporter: NSObject, TrackDelegate, @unchecked Sendable {
    private let role: String
    private let label: String
    private let lock = NSLock()
    private var last: Counters?

    /// Cumulative counters from one report.
    private struct Counters {
        var timestampUs: Double
        var frames: Double
        var bytes: Double
        var qpSum: Double
        var codingTime: Double
        var keyFrames: Double
        var dropped: Double = 0
        var jitterBufferDelay: Double = 0
        var jitterBufferEmitted: Double = 0
        var processingDelay: Double = 0
        var packetsLost: Double = 0
        var freezes: Double = 0
        var pli: Double = 0
        var nack: Double = 0
    }

    /// - Parameters:
    ///   - role: `host` or `viewer`.
    ///   - label: identifies the track on the line, e.g. `win=1234`.
    init(role: String, label: String) {
        self.role = role
        self.label = label
    }

    func track(_: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        let line: String?
        if let outbound = statistics.outboundRtpStream.filter({ $0.kind == "video" }).max(by: { ($0.frameWidth ?? 0) < ($1.frameWidth ?? 0) }) {
            line = hostLine(outbound, statistics)
        } else if let inbound = statistics.inboundRtpStream.first(where: { $0.kind == "video" }) {
            line = viewerLine(inbound, statistics)
        } else {
            line = nil
        }
        if let line { StatsLog.write("\(role) \(label) \(line)") }
    }

    private func hostLine(_ out: OutboundRtpStreamStatistics, _ stats: TrackStatistics) -> String? {
        let now = Counters(
            timestampUs: out.timestamp,
            frames: Double(out.framesEncoded ?? 0),
            bytes: Double(out.bytesSent ?? 0),
            qpSum: Double(out.qpSum ?? 0),
            codingTime: out.totalEncodeTime ?? 0,
            keyFrames: Double(out.keyFramesEncoded ?? 0),
            pli: Double(out.pliCount ?? 0),
            nack: Double(out.nackCount ?? 0)
        )
        guard let (d, seconds) = delta(now) else { return nil }
        let pair = selectedPair(stats)
        return [
            codecName(out.codecId, stats),
            "enc=\(out.encoderImplementation ?? "?")",
            "\(out.frameWidth ?? 0)x\(out.frameHeight ?? 0)",
            "fps=\(f1(d.frames / seconds))",
            "kbps=\(f0(d.bytes * 8 / seconds / 1000))",
            "target=\(out.targetBitrate.map { f0($0 / 1000) } ?? "?")",
            "bwe=\(pair?.availableOutgoingBitrate.map { f0($0 / 1000) } ?? "?")",
            "qp=\(d.frames > 0 && out.qpSum != nil ? f1(d.qpSum / d.frames) : "-")",
            "limit=\(out.qualityLimitationReason?.rawValue ?? "?")",
            "enc_ms=\(d.frames > 0 ? f2(d.codingTime / d.frames * 1000) : "-")",
            "key=\(f0(d.keyFrames))",
            "pli=\(f0(d.pli))",
            "nack=\(f0(d.nack))",
            "rtt=\(pair?.currentRoundTripTime.map { f1($0 * 1000) } ?? "?")",
        ].joined(separator: " ")
    }

    private func viewerLine(_ inbound: InboundRtpStreamStatistics, _ stats: TrackStatistics) -> String? {
        let now = Counters(
            timestampUs: inbound.timestamp,
            frames: Double(inbound.framesDecoded ?? 0),
            bytes: Double(inbound.bytesReceived ?? 0),
            qpSum: Double(inbound.qpSum ?? 0),
            codingTime: inbound.totalDecodeTime ?? 0,
            keyFrames: Double(inbound.keyFramesDecoded ?? 0),
            dropped: Double(inbound.framesDropped ?? 0),
            jitterBufferDelay: inbound.jitterBufferDelay ?? 0,
            jitterBufferEmitted: Double(inbound.jitterBufferEmittedCount ?? 0),
            processingDelay: inbound.totalProcessingDelay ?? 0,
            packetsLost: Double(inbound.packetsLost ?? 0),
            freezes: Double(inbound.freezeCount ?? 0)
        )
        guard let (d, seconds) = delta(now) else { return nil }
        return [
            codecName(inbound.codecId, stats),
            "dec=\(inbound.decoderImplementation ?? "?")",
            "\(inbound.frameWidth ?? 0)x\(inbound.frameHeight ?? 0)",
            "fps=\(f1(d.frames / seconds))",
            "kbps=\(f0(d.bytes * 8 / seconds / 1000))",
            "qp=\(d.frames > 0 && inbound.qpSum != nil ? f1(d.qpSum / d.frames) : "-")",
            "dropped=\(f0(d.dropped))",
            // Time a frame waited in the jitter buffer: what a playout delay of 0 would save.
            "jb_ms=\(d.jitterBufferEmitted > 0 ? f1(d.jitterBufferDelay / d.jitterBufferEmitted * 1000) : "-")",
            "dec_ms=\(d.frames > 0 ? f2(d.codingTime / d.frames * 1000) : "-")",
            // First packet in to decoded, per frame: the viewer's share of the latency.
            "proc_ms=\(d.frames > 0 ? f1(d.processingDelay / d.frames * 1000) : "-")",
            "key=\(f0(d.keyFrames))",
            "lost=\(f0(d.packetsLost))",
            "freezes=\(f0(d.freezes))",
            "rtt=\(selectedPair(stats)?.currentRoundTripTime.map { f1($0 * 1000) } ?? "?")",
        ].joined(separator: " ")
    }

    /// The change since the last report, and the seconds it covers; nil on the first report,
    /// and after a reset (a new stream starts its counters from zero).
    private func delta(_ now: Counters) -> (Counters, Double)? {
        lock.lock()
        defer { lock.unlock() }
        defer { last = now }
        guard let last, now.timestampUs > last.timestampUs, now.frames >= last.frames else { return nil }
        let seconds = (now.timestampUs - last.timestampUs) / 1_000_000
        let d = Counters(
            timestampUs: now.timestampUs - last.timestampUs,
            frames: now.frames - last.frames,
            bytes: now.bytes - last.bytes,
            qpSum: now.qpSum - last.qpSum,
            codingTime: now.codingTime - last.codingTime,
            keyFrames: now.keyFrames - last.keyFrames,
            dropped: now.dropped - last.dropped,
            jitterBufferDelay: now.jitterBufferDelay - last.jitterBufferDelay,
            jitterBufferEmitted: now.jitterBufferEmitted - last.jitterBufferEmitted,
            processingDelay: now.processingDelay - last.processingDelay,
            packetsLost: now.packetsLost - last.packetsLost,
            freezes: now.freezes - last.freezes,
            pli: now.pli - last.pli,
            nack: now.nack - last.nack
        )
        return (d, seconds)
    }

    /// `H264/640c1f`: the codec, and for H.264 the profile-level-id that was negotiated.
    private func codecName(_ id: String?, _ stats: TrackStatistics) -> String {
        guard let codec = stats.codec.first(where: { $0.id == id }) else { return "codec=?" }
        let name = (codec.mimeType ?? "?").replacingOccurrences(of: "video/", with: "")
        let profile = codec.sdpFmtpLine?
            .split(separator: ";")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("profile-level-id=") }?
            .split(separator: "=").last
        return profile.map { "\(name)/\($0)" } ?? name
    }

    private func selectedPair(_ stats: TrackStatistics) -> IceCandidatePairStatistics? {
        if let id = stats.transportStats?.selectedCandidatePairId,
           let pair = stats.iceCandidatePair.first(where: { $0.id == id })
        {
            return pair
        }
        return stats.iceCandidatePair.first { $0.nominated == true }
    }

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    private func f2(_ v: Double) -> String { String(format: "%.2f", v) }
}
