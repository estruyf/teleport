import CoreMedia
import Foundation
import LiveKit
import TeleportCore
import VideoToolbox

/// `Teleport --encoder-selftest [h264|h265] [kbps] [width] [height] [setting=value…]`: runs `TeleportEncoder` the
/// way WebRTC does, then parses its Annex B output back, decodes it with VideoToolbox and compares
/// the picture with what went in. Checks the bitstream WebRTC gets and what a paint-over buys,
/// without a second Mac or a network. Nothing is sent anywhere.
enum EncoderSelfTest {
    static func run(_ arguments: [String]) -> Int32 {
        // key=value arguments override `video` settings, e.g. prioritizeSpeed=false paintOverMaxQP=18.
        let overrides = Dictionary(arguments.filter { $0.contains("=") }.map {
            let parts = $0.split(separator: "=", maxSplits: 1)
            return (String(parts[0]), String(parts[1]))
        }, uniquingKeysWith: { $1 })
        let args = arguments.filter { !$0.contains("=") }
        let hevc = args.first == "h265"
        let kbps = args.count > 1 ? UInt32(args[1]) ?? 8000 : 8000
        let width = args.count > 2 ? Int(args[2]) ?? 3840 : 3840
        let height = args.count > 3 ? Int(args[3]) ?? 2400 : 2400
        var config = VideoConfig()
        config.paintOver = true
        config.codec = hevc ? .h265 : .h264
        config.prioritizeSpeed = overrides["prioritizeSpeed"].map { $0 == "true" }
        config.paintOverMaxQP = overrides["paintOverMaxQP"].flatMap { Int($0) }
        config.paintOverBitrateBoost = overrides["paintOverBitrateBoost"].flatMap { Double($0) }
        config.paintOverFrames = overrides["paintOverFrames"].flatMap { Int($0) }
        let tuning = VideoTuning(config)
        print("encoder self-test: \(hevc ? "H.265" : "H.264") \(width)x\(height) at \(kbps) kbps; \(tuning)")

        let content = Content(width: width, height: height)
        guard let failures = check(hevc: hevc, kbps: kbps, width: width, height: height, tuning: tuning, content: content) else {
            print("FAIL: startEncode")
            return 1
        }
        compare(hevc: hevc, kbps: kbps, width: width, height: height, tuning: tuning, content: content)
        print(failures == 0 ? "PASS: every frame was Annex B and decoded" : "FAIL: \(failures) frame(s) did not decode or were not Annex B")
        return failures == 0 ? 0 : 1
    }

    /// An encoder as WebRTC would set it up, and a way to push one frame through it.
    private final class Harness {
        let encoder: TeleportEncoder
        let outputs = Outputs()
        let decoder: Decoder
        let width: Int
        let height: Int
        var rtp: UInt32 = 0
        var ns: Int64 = 0

        init?(hevc: Bool, kbps: UInt32, width: Int, height: Int, tuning: VideoTuning) {
            let codec = hevc ? VideoCodecInfo(name: "H265") : VideoCodecInfo(name: "H264", parameters: ["profile-level-id": "640c1f", "packetization-mode": "1"])
            encoder = TeleportEncoder(codec: codec, tuning: tuning)
            decoder = Decoder(hevc: hevc)
            self.width = width
            self.height = height
            let outputs = outputs
            encoder.setCallback { frame in
                outputs.append(frame)
                return true
            }
            let settings = VideoEncoderSettings(name: hevc ? "H265" : "H264", dimensions: Dimensions(width: Int32(width), height: Int32(height)),
                                                startBitrateKbps: kbps, maxBitrateKbps: kbps, minBitrateKbps: 30, maxFramerate: 60, qpMax: 51, mode: .screensharing)
            guard encoder.startEncode(with: settings, numberOfCores: 8) == .ok else { return nil }
        }

        /// Encodes one frame and returns what came out (VideoToolbox may drop it).
        func encode(_ buffer: CVPixelBuffer, _ kind: FrameKind?, key: Bool = false) -> EncodedVideoFrame? {
            kind?.tag(buffer)
            rtp &+= 1500
            ns += 16_666_667
            let frame = VideoFrame(dimensions: Dimensions(width: Int32(width), height: Int32(height)), rotation: ._0,
                                   timeStampNs: ns, rtpTimestamp: rtp, buffer: CVPixelVideoBuffer(pixelBuffer: buffer))
            let before = outputs.count
            guard encoder.encode(frame, frameTypes: [key ? .key : .delta]) == .ok else { return nil }
            // One frame in flight at a time keeps the report in order; waits at most 200 ms.
            for _ in 0 ..< 200 {
                if outputs.count > before { return outputs.last }
                usleep(1000)
            }
            return nil
        }

        /// Encodes, decodes and compares; nil PSNR when it was dropped or didn't decode.
        /// The stamp read back from the last decoded picture, as the viewer's probe reads it.
        var lastRead: TestPattern.Stamp?

        func round(_ buffer: CVPixelBuffer, _ kind: FrameKind?, key: Bool = false) -> (out: EncodedVideoFrame?, psnr: Double?, annexB: Bool) {
            guard let out = encode(buffer, kind, key: key) else { return (nil, nil, true) }
            let units = AnnexBReader.units(out.data)
            let annexB = !units.isEmpty && out.data.starts(with: [0, 0, 0, 1])
            let picture = decoder.decode(units, key: out.frameType == .key)
            lastRead = picture.flatMap(Self.readStamp)
            let psnr = picture.map { Content.lumaPSNR(buffer, $0, width: width, height: height) }
            return (out, psnr, annexB)
        }

        private static func readStamp(_ picture: CVPixelBuffer) -> TestPattern.Stamp? {
            CVPixelBufferLockBaseAddress(picture, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(picture, 0) else { return nil }
            let luma = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(picture, 0)
            return TestPattern.read(scale: 2) { x, y in luma[y * stride + x] }
        }
    }

    /// The path WebRTC drives, frame by frame: every output must be Annex B and decode.
    /// Returns the number of failures, or nil when the encoder didn't start.
    private static func check(hevc: Bool, kbps: UInt32, width: Int, height: Int, tuning: VideoTuning, content: Content) -> Int? {
        guard let harness = Harness(hevc: hevc, kbps: kbps, width: width, height: height, tuning: tuning) else { return nil }
        var failures = 0
        var unreadable = 0
        var decodedFrames = 0
        func step(_ label: String, _ buffer: CVPixelBuffer, _ kind: FrameKind?, key: Bool = false) {
            let (result, decoded, wellFormed) = harness.round(buffer, kind, key: key)
            guard let out = result else {
                print(String(format: "  %-20@ dropped by VideoToolbox", label as NSString))
                return
            }
            var psnr = decoded.map { String(format: "%.2f dB", $0) } ?? "DECODE FAILED"
            if decoded == nil { failures += 1 } else { decodedFrames += 1 }
            if !wellFormed { failures += 1 }
            // The probe must read the stamp that was drawn, or nothing; never a wrong one.
            if let read = harness.lastRead {
                if read != Content.lastStamp {
                    failures += 1
                    psnr += "  WRONG STAMP"
                }
            } else {
                unreadable += 1
                psnr += "  stamp unreadable"
            }
            print(String(format: "  %-20@ %8.1f KB  %@  %@  rtp=%u%@", label as NSString, Double(out.data.count) / 1024, psnr as NSString,
                         (out.frameType == .key ? "key  " : "delta") as NSString, out.rtpTimestamp, wellFormed ? "" : "  NOT ANNEX B"))
        }

        step("keyframe", content.frame(offset: 0), .motion, key: true)
        var offset = 0
        for i in 1 ... 20 {
            offset += 6
            step(i % 5 == 0 ? "scroll \(i)" : "", content.frame(offset: offset), .motion)
        }
        let still = content.frame(offset: offset)
        step("still (refresh)", still, .still)
        for i in 1 ... tuning.paintOverFrames { step("paint-over \(i)", still, .paintOver) }
        step("still after", still, .still)
        for i in 1 ... 5 {
            offset += 6
            step(i == 5 ? "motion again" : "", content.frame(offset: offset), .motion)
        }
        step("keyframe asked", content.frame(offset: offset), .still, key: true)
        for i in 1 ... tuning.paintOverFrames { step("still after key \(i)", content.frame(offset: offset), .still) }

        _ = harness.encoder.releaseEncoder()
        print("  test-pattern stamp read back from \(decodedFrames - unreadable) of \(decodedFrames) decoded frames")
        return failures
    }

    /// What a paint-over buys over today's plain repeats of the still frame: the same motion,
    /// then eight frames of the still picture, with and without the first ones painted over.
    private static func compare(hevc: Bool, kbps: UInt32, width: Int, height: Int, tuning: VideoTuning, content: Content) {
        // The baseline runs with paint-over off, so nothing in it is sharpened on purpose.
        var plain = tuning
        plain.paintOver = false
        let tails: [(VideoTuning, [FrameKind])] = [
            (plain, Array(repeating: .still, count: 8)),
            (tuning, Array(repeating: .paintOver, count: tuning.paintOverFrames) + Array(repeating: .still, count: 8 - tuning.paintOverFrames)),
        ]
        var columns: [[(Double, Double?)]] = []
        for (tuning, tail) in tails {
            guard let harness = Harness(hevc: hevc, kbps: kbps, width: width, height: height, tuning: tuning) else { return }
            _ = harness.round(content.frame(offset: 0), .motion, key: true)
            var offset = 0
            for _ in 0 ..< 30 {
                offset += 6
                _ = harness.round(content.frame(offset: offset), .motion)
            }
            let still = content.frame(offset: offset)
            columns.append(tail.map { kind in
                let (out, psnr, _) = harness.round(still, kind)
                return (Double(out?.data.count ?? 0) / 1024, psnr)
            })
            _ = harness.encoder.releaseEncoder()
        }
        print("  after 30 frames of scrolling, the still picture (KB, luma PSNR):")
        print("    frame   repeats (today)        paint-over")
        var totals = [0.0, 0.0]
        for i in 0 ..< 8 {
            let cells = (0 ..< 2).map { c -> String in
                let (kb, psnr) = columns[c][i]
                totals[c] += kb
                return String(format: "%7.1f KB %@", kb, psnr.map { String(format: "%5.2f dB", $0) } ?? " dropped") as String
            }
            print("    \(i + 1)       \(cells[0])    \(cells[1])")
        }
        print(String(format: "    total   %7.1f KB              %7.1f KB", totals[0], totals[1]))
    }
}

/// Frames the encoder delivered, from its output thread.
private final class Outputs: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [EncodedVideoFrame] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    var last: EncodedVideoFrame? { lock.lock(); defer { lock.unlock() }; return frames.last }
    func append(_ frame: EncodedVideoFrame) { lock.lock(); frames.append(frame); lock.unlock() }
}

/// Text-like test content: dark glyph strokes on white, taller than the frame so it can scroll.
private struct Content {
    let width: Int
    let height: Int
    private let luma: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        var luma = [UInt8](repeating: 235, count: width * (height + 600))
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for line in 0 ..< (height + 600) / 24 {
            var x = 200
            while x < width - 200 {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                for gy in 0 ..< 14 {
                    for gx in 0 ..< 6 where (seed >> UInt64((gy * 3 + gx) % 64)) & 1 == 1 {
                        luma[(line * 24 + 5 + gy) * width + x + gx] = 30
                    }
                }
                x += 8 + Int(seed % 3) * 4
            }
        }
        self.luma = luma
    }

    /// Frames counted so far; each frame carries the next stamp, as TeleportTestPattern draws it.
    private static let counter = Counter()
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt32 = 0
        func next() -> UInt32 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    /// The stamp drawn into the last frame made.
    nonisolated(unsafe) static var lastStamp: TestPattern.Stamp?

    func frame(offset: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        luma.withUnsafeBufferPointer { src in
            for row in 0 ..< height { memcpy(y + row * stride, src.baseAddress! + (row + offset) * width, width) }
        }
        // The test pattern's stamp at 2x, on its white surround, as TeleportTestPattern draws it.
        let stamp = TestPattern.Stamp(counter: Self.counter.next(), timeMs: TestPattern.nowMs(), mode: .text)
        Self.lastStamp = stamp
        let block = Int(TestPattern.block * 2)
        for row in Int(TestPattern.originY * 2) - 12 ..< Int(TestPattern.originY * 2) + TestPattern.rows * block + 12 {
            memset(y + row * stride + Int(TestPattern.originX * 2) - 12, 235, TestPattern.columns * block + 24)
        }
        for (index, bit) in TestPattern.bits(stamp).enumerated() where bit {
            let center = TestPattern.center(of: index)
            for row in Int(center.y * 2) - block / 2 ..< Int(center.y * 2) + block / 2 {
                memset(y + row * stride + Int(center.x * 2) - block / 2, 16, block)
            }
        }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    static func lumaPSNR(_ a: CVPixelBuffer, _ b: CVPixelBuffer, width: Int, height: Int) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        var sum: UInt64 = 0
        for row in 0 ..< height {
            for x in 0 ..< width {
                let d = Int(pa[row * sa + x]) - Int(pb[row * sb + x])
                sum += UInt64(d * d)
            }
        }
        let mse = Double(sum) / Double(width * height)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
}

/// Splits Annex B back into NAL units, as a receiver's depacketizer would see them.
private enum AnnexBReader {
    static func units(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append(i + 4)
                i += 4
            } else {
                i += 1
            }
        }
        return starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] - 4 : bytes.count
            return Data(bytes[start ..< end])
        }
    }
}

/// VideoToolbox decoding of NAL units, keeping the reference chain across frames.
private final class Decoder {
    let hevc: Bool
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    init(hevc: Bool) { self.hevc = hevc }

    private func isParameterSet(_ unit: Data) -> Bool {
        guard let first = unit.first else { return false }
        return hevc ? (32 ... 34).contains((first >> 1) & 0x3F) : [7, 8].contains(first & 0x1F)
    }

    func decode(_ units: [Data], key: Bool) -> CVPixelBuffer? {
        let parameterSets = units.filter(isParameterSet)
        if key, !parameterSets.isEmpty {
            guard let newFormat = makeFormat(parameterSets) else { return nil }
            if format == nil || !CMFormatDescriptionEqual(format, otherFormatDescription: newFormat) {
                format = newFormat
                session.map { VTDecompressionSessionInvalidate($0) }
                var created: VTDecompressionSession?
                let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary
                VTDecompressionSessionCreate(allocator: nil, formatDescription: newFormat, decoderSpecification: nil,
                                             imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &created)
                session = created
            }
        }
        guard let format, let session else { return nil }
        // Back to length-prefixed NAL units for the decoder.
        var avcc = Data()
        for unit in units where !isParameterSet(unit) {
            var length = UInt32(unit.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block
        else { return nil }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample
        else { return nil }
        var picture: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { picture = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr ? picture : nil
    }

    private func makeFormat(_ sets: [Data]) -> CMVideoFormatDescription? {
        let copies = sets.map { [UInt8]($0) }
        var pointers: [UnsafePointer<UInt8>] = []
        var allocated: [UnsafeMutablePointer<UInt8>] = []
        defer { allocated.forEach { $0.deallocate() } }
        for bytes in copies {
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            allocated.append(pointer)
            pointers.append(UnsafePointer(pointer))
        }
        let sizes = copies.map(\.count)
        var format: CMVideoFormatDescription?
        let status = hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                  parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                  parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }
}
