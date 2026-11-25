import CoreVideo
import Foundation
import LiveKit
import TeleportCore

/// The viewer half of the measurement harness (`video.probe`): reads TeleportTestPattern's stamp
/// from every decoded frame and writes to stats.log, per second, how many new frames arrived and
/// how old they were, and every ten seconds p50/p99 latency and the worst second's frame rate.
///
/// Latency runs from the host drawing the frame to this Mac decoding it: capture, encode, network,
/// jitter buffer and decode, but not the two displays. On one Mac (a loopback test) both ends read
/// the same clock; between two, add `video.probeClockCorrectionMs` (docs/video-quality.md).
final class PatternProbe: NSObject, VideoRenderer, @unchecked Sendable {
    private let label: String
    private let correctionMs: Int64
    private let lock = NSLock()
    private var scale: Double
    private var lastCounter: UInt32?
    private var current: Bucket?
    private var recent: [Bucket] = []

    /// One second of frames.
    private struct Bucket {
        var startMs: UInt64
        var mode: TestPattern.Mode?
        var latencies: [Double] = []
        /// Decoded frames showing a stamp seen before: refreshes and paint-overs.
        var repeats = 0
        /// Stamps that never arrived: drawn on the host, but not captured, dropped or not decoded.
        var missed = 0
        /// Frames whose stamp didn't read: no pattern in view, or too blurry to read.
        var unreadable = 0
    }

    init(label: String, scale: Double, correctionMs: Int) {
        self.label = label
        self.scale = scale
        self.correctionMs = Int64(correctionMs)
    }

    /// Video pixels per host point, once the viewer knows it.
    func set(scale: Double) {
        lock.lock()
        self.scale = scale
        lock.unlock()
    }

    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }

    func render(frame: VideoFrame) {
        let now = TestPattern.nowMs()
        lock.lock()
        let scale = scale
        lock.unlock()
        let stamp = Self.read(frame, scale: scale)
        lock.lock()
        let lines = record(stamp, nowMs: now)
        lock.unlock()
        for line in lines { StatsLog.write(line) }
    }

    // MARK: - Reading

    private static func read(_ frame: VideoFrame, scale: Double) -> TestPattern.Stamp? {
        let need = TestPattern.extent(scale: scale)
        if let pixelBuffer = (frame.buffer as? CVPixelVideoBuffer)?.pixelBuffer {
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let planar = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format)
            if planar || format == kCVPixelFormatType_32BGRA {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
                guard CVPixelBufferGetWidth(pixelBuffer) >= need.width, CVPixelBufferGetHeight(pixelBuffer) >= need.height,
                      let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer)
                else { return nil }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
                // Luma, or green for BGRA: close enough for black against white.
                let step = planar ? 1 : 4, offset = planar ? 0 : 1
                return TestPattern.read(scale: scale) { x, y in bytes[y * stride + x * step + offset] }
            }
        }
        // Anything else WebRTC hands over gets converted; slower, but it still reads.
        guard let i420 = frame.toI420(), Int(i420.width) >= need.width, Int(i420.height) >= need.height else { return nil }
        let luma = i420.dataY
        let stride = Int(i420.strideY)
        return withExtendedLifetime(i420) {
            TestPattern.read(scale: scale) { x, y in luma[y * stride + x] }
        }
    }

    // MARK: - Counting

    /// Call with `lock` held. Returns the lines to log.
    private func record(_ stamp: TestPattern.Stamp?, nowMs: UInt64) -> [String] {
        var lines: [String] = []
        if current == nil { current = Bucket(startMs: nowMs) }
        // Close every second that has ended; seconds with no frame at all show as 0 fps.
        var closed = 0
        while let bucket = current, nowMs >= bucket.startMs + 1000, closed < 60 {
            lines += close(bucket)
            current = Bucket(startMs: bucket.startMs + 1000, mode: bucket.mode)
            closed += 1
        }
        if closed == 60 { current = Bucket(startMs: nowMs, mode: current?.mode) }

        guard let stamp else {
            current?.unreadable += 1
            return lines
        }
        if stamp.counter == lastCounter {
            current?.repeats += 1
            return lines
        }
        if let last = lastCounter {
            let gap = (stamp.counter &- last) & 0x3F_FFFF
            // A big jump is a restarted pattern app or frames out of order, not a loss.
            if gap > 1, gap < 600 { current?.missed += Int(gap) - 1 }
        }
        lastCounter = stamp.counter
        current?.mode = stamp.mode
        current?.latencies.append(Double(TestPattern.ageMs(of: stamp, nowMs: nowMs) + correctionMs))
        return lines
    }

    private func close(_ bucket: Bucket) -> [String] {
        var lines = ["probe \(label) mode=\(bucket.mode?.name ?? "?") fps=\(bucket.latencies.count) repeats=\(bucket.repeats)"
            + " missed=\(bucket.missed) unreadable=\(bucket.unreadable) \(Self.percentiles(bucket.latencies))"]
        recent.append(bucket)
        if recent.count == 10 {
            // Only the seconds in the latest mode, so a switch halfway doesn't blur the two.
            let mode = bucket.mode
            let same = recent.filter { $0.mode == mode }
            let rates = same.map(\.latencies.count)
            lines.append("probe-summary \(label) mode=\(mode?.name ?? "?") seconds=\(same.count)"
                + " worst_fps=\(rates.min() ?? 0) mean_fps=\(String(format: "%.1f", Double(rates.reduce(0, +)) / Double(max(1, rates.count))))"
                + " missed=\(same.map(\.missed).reduce(0, +)) \(Self.percentiles(same.flatMap(\.latencies)))")
            recent.removeAll()
        }
        return lines
    }

    private static func percentiles(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "lat_p50=- lat_p99=- lat_max=-" }
        let sorted = values.sorted()
        func at(_ q: Double) -> String { String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q + 0.5))]) }
        return "lat_p50=\(at(0.5)) lat_p99=\(at(0.99)) lat_max=\(at(1))"
    }
}
