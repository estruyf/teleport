@testable import TeleportCore
import Testing

/// The pattern is how latency is measured; a misread must be rejected, never reported.
@Suite struct TestPatternTests {
    @Test(arguments: TestPattern.Mode.allCases)
    func roundTrips(_ mode: TestPattern.Mode) {
        let stamp = TestPattern.Stamp(counter: 123_456, timeMs: TestPattern.nowMs(), mode: mode)
        let bits = TestPattern.bits(stamp)
        #expect(bits.count == TestPattern.columns * TestPattern.rows)
        #expect(TestPattern.decode(bits) == stamp)
    }

    @Test func wrapsInsteadOfOverflowing() {
        let stamp = TestPattern.Stamp(counter: 0xFFFF_FFFF, timeMs: .max, mode: .text)
        #expect(stamp.counter == 0x3F_FFFF)
        #expect(TestPattern.decode(TestPattern.bits(stamp)) == stamp)
    }

    @Test func anyFlippedBlockIsRejected() {
        let bits = TestPattern.bits(TestPattern.Stamp(counter: 42, timeMs: 1_790_000_000_000, mode: .drag))
        for index in bits.indices {
            var damaged = bits
            damaged[index].toggle()
            #expect(TestPattern.decode(damaged) == nil, "block \(index)")
        }
    }

    @Test func blankAndSolidFramesAreRejected() {
        #expect(TestPattern.decode(Array(repeating: false, count: 72)) == nil)
        #expect(TestPattern.decode(Array(repeating: true, count: 72)) == nil)
    }

    @Test func ageSurvivesTheClockWrap() {
        let now = TestPattern.nowMs()
        let drawn = TestPattern.Stamp(counter: 1, timeMs: now - 45, mode: .text)
        #expect(TestPattern.ageMs(of: drawn, nowMs: now) == 45)
        // Drawn just before the 40-bit clock wrapped, read just after.
        let beforeWrap = TestPattern.Stamp(counter: 1, timeMs: 0xFF_FFFF_FFF0, mode: .text)
        #expect(TestPattern.ageMs(of: beforeWrap, nowMs: 0x100_0000_0010) == 32)
        // A host clock 20 ms ahead reads as -20, not as 34 years.
        #expect(TestPattern.ageMs(of: TestPattern.Stamp(counter: 1, timeMs: now + 20, mode: .idle), nowMs: now) == -20)
    }
}
