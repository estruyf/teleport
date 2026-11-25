import Foundation

/// The block pattern that TeleportTestPattern draws into its window and the viewer's probe reads
/// back from decoded frames: a frame counter, the time it was drawn and the test mode, so the
/// viewer can tell latency and frame rate from the pictures alone. See docs/video-quality.md.
///
/// 72 blocks in 3 rows of 24, black for 1 and white for 0, at a fixed place in the window:
/// big enough to survive a blurry, low-bitrate frame. A checksum rejects frames caught mid-update.
public enum TestPattern {
    public static let columns = 24
    public static let rows = 3
    /// Side of one block, in window points.
    public static let block: Double = 12
    /// Top-left corner of the pattern, in points from the window's top-left corner.
    public static let originX: Double = 24
    public static let originY: Double = 48

    public enum Mode: Int, CaseIterable, Sendable {
        case idle, text, drag, animation

        public var name: String { "\(self)" }
    }

    public struct Stamp: Equatable, Sendable {
        /// Frames drawn, wrapping at 2^22 (19 hours at 60 fps).
        public var counter: UInt32
        /// Wall-clock milliseconds when it was drawn, wrapping at 2^40 (34 years).
        public var timeMs: UInt64
        public var mode: Mode

        public init(counter: UInt32, timeMs: UInt64, mode: Mode) {
            self.counter = counter & 0x3F_FFFF
            self.timeMs = timeMs & 0xFF_FFFF_FFFF
            self.mode = mode
        }
    }

    /// The 72 bits, row by row from the top-left block.
    public static func bits(_ stamp: Stamp) -> [Bool] {
        let payload = UInt64(stamp.counter) << 42 | UInt64(stamp.mode.rawValue) << 40 | stamp.timeMs
        let check = checksum(payload)
        return (0 ..< 64).map { payload >> (63 - UInt64($0)) & 1 == 1 }
            + (0 ..< 8).map { check >> (7 - UInt8($0)) & 1 == 1 }
    }

    /// The stamp in 72 bits, or nil when the checksum doesn't match (a torn or garbled frame).
    public static func decode(_ bits: [Bool]) -> Stamp? {
        guard bits.count == columns * rows else { return nil }
        let payload = bits[0 ..< 64].reduce(UInt64(0)) { $0 << 1 | ($1 ? 1 : 0) }
        let check = bits[64 ..< 72].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) }
        guard check == checksum(payload), let mode = Mode(rawValue: Int(payload >> 40 & 3)) else { return nil }
        return Stamp(counter: UInt32(payload >> 42), timeMs: payload & 0xFF_FFFF_FFFF, mode: mode)
    }

    /// Centre of block `index`, in points from the window's top-left corner.
    public static func center(of index: Int) -> (x: Double, y: Double) {
        let column = index % columns, row = index / columns
        return (originX + (Double(column) + 0.5) * block, originY + (Double(row) + 0.5) * block)
    }

    /// Reads the stamp from a picture of the window: `brightness(x, y)` gives a pixel's luma (or
    /// any channel) 0–255, `scale` is pixels per point. Dark is 1. Nil if it doesn't check out.
    public static func read(scale: Double, brightness: (Int, Int) -> UInt8) -> Stamp? {
        let bits = (0 ..< columns * rows).map { index -> Bool in
            let center = center(of: index)
            return brightness(Int(center.x * scale), Int(center.y * scale)) < 128
        }
        return decode(bits)
    }

    /// The rectangle `read` samples, in pixels at `scale`; a picture smaller than this can't hold the pattern.
    public static func extent(scale: Double) -> (width: Int, height: Int) {
        (Int((originX + Double(columns) * block) * scale) + 1, Int((originY + Double(rows) * block) * scale) + 1)
    }

    /// Fletcher-style, so a swapped pair of bytes doesn't pass.
    static func checksum(_ payload: UInt64) -> UInt8 {
        var a: UInt16 = 0x5A, b: UInt16 = 0
        for shift in stride(from: 56, through: 0, by: -8) {
            a = (a + UInt16(payload >> UInt64(shift) & 0xFF)) % 255
            b = (b + a) % 255
        }
        return UInt8(truncatingIfNeeded: a ^ b << 4 ^ b >> 4)
    }

    public static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// Milliseconds from the stamp to `nowMs`. The stamp keeps 40 bits of the clock, which today's
    /// millisecond count already passes, so the difference is taken in that width; negative when
    /// the drawing Mac's clock is ahead.
    public static func ageMs(of stamp: Stamp, nowMs: UInt64) -> Int64 {
        let mask: UInt64 = 0xFF_FFFF_FFFF
        let diff = (nowMs &- stamp.timeMs) & mask
        return diff > mask / 2 ? Int64(diff) - Int64(mask) - 1 : Int64(diff)
    }
}
