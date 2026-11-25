// What VideoToolbox on this Mac does with screen-like content, measured rather than assumed.
//
// Encodes synthetic text at the virtual display's size, decodes it again and compares with the
// source, so every number is real: luma PSNR, frame size, dropped frames, encode time.
//
// Usage: swift -O scripts/vt-probe.swift [kbps] [width] [height]
//        (defaults: 8000 kbps, 3840×2400; run it on the host Mac, its encoder is the one that counts)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let args = CommandLine.arguments
let kbps = args.count > 1 ? Int(args[1]) ?? 8000 : 8000
let width = args.count > 2 ? Int(args[2]) ?? 3840 : 3840
let height = args.count > 3 ? Int(args[3]) ?? 2400 : 2400
let fps = 60

// MARK: - Synthetic content

/// Dark "glyphs" on white in 16 px lines, plus a coloured sidebar: hard edges everywhere, like code.
/// Taller than the frame so frames can scroll through it.
let scrollRange = 1200
let lumaSource: [UInt8] = {
    var luma = [UInt8](repeating: 235, count: width * (height + scrollRange))
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return seed
    }
    let lineHeight = 24
    for line in 0 ..< (height + scrollRange) / lineHeight {
        var x = 300 + Int(next() % 120)
        let lineEnd = 300 + Int(next() % UInt64(width - 600))
        while x < lineEnd {
            let glyph = 7 + Int(next() % 4)
            let pattern = next()
            for gy in 0 ..< 14 {
                for gx in 0 ..< glyph - 2 where (pattern >> UInt64((gy * 3 + gx) % 64)) & 1 == 1 {
                    let y = line * lineHeight + 5 + gy
                    luma[y * width + x + gx] = 30
                }
            }
            x += glyph + (next() % 9 == 0 ? glyph : 0)
        }
    }
    for y in 0 ..< height + scrollRange {
        for x in 0 ..< 280 { luma[y * width + x] = UInt8(60 + (y / 40 % 2) * 30) }
    }
    return luma
}()

func makeFrame(offset: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    lumaSource.withUnsafeBufferPointer { src in
        for row in 0 ..< height {
            memcpy(y + row * yStride, src.baseAddress! + (row + offset) * width, width)
        }
    }
    let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    for row in 0 ..< height / 2 {
        memset(uv + row * uvStride, 128, width)
        // A blue sidebar, so chroma has edges too.
        for x in 0 ..< 140 { uv[row * uvStride + x * 2] = 180; uv[row * uvStride + x * 2 + 1] = 100 }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

func lumaPSNR(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
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

// MARK: - Bitstream details

func unescape(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var zeros = 0
    for byte in bytes {
        if zeros >= 2, byte == 3 { zeros = 0; continue }
        zeros = byte == 0 ? zeros + 1 : 0
        out.append(byte)
    }
    return out
}

/// "High@5.2" / "Main@6.1", read from the SPS VideoToolbox actually wrote.
func profileLevel(_ format: CMFormatDescription, hevc: Bool) -> String {
    var pointer: UnsafePointer<UInt8>?
    var size = 0
    if hevc {
        // Index 1 is the SPS (VPS, SPS, PPS).
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return "?" }
        let sps = unescape(Array(UnsafeBufferPointer(start: pointer, count: size)))
        guard sps.count > 14 else { return "?" }
        let profile = sps[3] & 0x1F
        return "\(profile == 1 ? "Main" : profile == 2 ? "Main10" : "profile\(profile)")@\(Double(sps[14]) / 30)"
    }
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer, size > 3 else { return "?" }
    let profile = pointer[1], level = pointer[3]
    let name = [66: "Baseline", 77: "Main", 100: "High"][Int(profile)] ?? "profile\(profile)"
    return "\(name)@\(Double(level) / 10)"
}

// MARK: - Encode and decode

struct Encoded {
    var sample: CMSampleBuffer?
    var dropped = false
    var bytes: Int { sample.map { CMSampleBufferGetTotalSampleSize($0) } ?? 0 }
    var keyframe: Bool {
        guard let sample,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        else { return false }
        return !(attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
}

final class Probe {
    let session: VTCompressionSession
    let hevc: Bool
    var decoder: VTDecompressionSession?
    var pts = 0
    var encodeMs: [Double] = []

    init?(hevc: Bool, lowLatency: Bool, profile: CFString?) {
        self.hevc = hevc
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            print("    session create failed: \(status)")
            return nil
        }
        self.session = session
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 100_000)
        set(kVTCompressionPropertyKey_AverageBitRate, kbps * 1000)
        set(kVTCompressionPropertyKey_DataRateLimits, [kbps * 1000 * 3 / 2 / 8, 1] as CFArray)
        if let profile { set(kVTCompressionPropertyKey_ProfileLevel, profile) }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    @discardableResult
    func set(_ key: CFString, _ value: Any) -> OSStatus {
        VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
    }

    func read(_ key: CFString) -> Any? {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: $0)
        }
        return status == noErr ? value : nil
    }

    func encode(_ frame: CVPixelBuffer, key: Bool = false, baseQP: Int? = nil) -> Encoded {
        var result = Encoded()
        var props: [CFString: Any] = [:]
        if key { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        if let baseQP { props[kVTEncodeFrameOptionKey_BaseFrameQP] = baseQP }
        let pts = CMTime(value: CMTimeValue(self.pts), timescale: CMTimeScale(fps))
        self.pts += 1
        let start = Date()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: props.isEmpty ? nil : props as CFDictionary, infoFlagsOut: nil
        ) { status, flags, sample in
            if status != noErr { print("    encode error \(status)") }
            if flags.contains(.frameDropped) { result.dropped = true }
            result.sample = sample
        }
        if status != noErr { print("    encode call failed \(status)") }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        encodeMs.append(Date().timeIntervalSince(start) * 1000)
        if result.sample == nil { result.dropped = true }
        return result
    }

    func decode(_ encoded: Encoded) -> CVPixelBuffer? {
        guard let sample = encoded.sample, let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        if decoder == nil {
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary
            var created: VTDecompressionSession?
            VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &created)
            decoder = created
        }
        guard let decoder else { return nil }
        var image: CVPixelBuffer?
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, buffer, _, _ in
            image = buffer
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        return image
    }
}

/// One encode + decode, keeping the decoder's reference chain intact, and a line about it.
struct Step {
    let label: String
    let bytes: Int
    let psnr: Double?
    let dropped: Bool
    let key: Bool
}

func run(_ probe: Probe, _ frame: CVPixelBuffer, label: String, key: Bool = false, baseQP: Int? = nil, lastGood: inout CVPixelBuffer?) -> Step {
    let encoded = probe.encode(frame, key: key, baseQP: baseQP)
    var psnr: Double?
    if !encoded.dropped, let image = probe.decode(encoded) {
        psnr = lumaPSNR(frame, image)
        lastGood = image
    } else if let lastGood {
        // The viewer keeps showing the last frame.
        psnr = lumaPSNR(frame, lastGood)
    }
    return Step(label: label, bytes: encoded.bytes, psnr: psnr, dropped: encoded.dropped, key: encoded.keyframe)
}

func show(_ steps: [Step]) {
    for step in steps {
        let psnr = step.psnr.map { String(format: "%5.2f dB", $0) } ?? "   -    "
        let size = String(format: "%7.1f KB", Double(step.bytes) / 1024)
        print("      \(step.label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(size)  \(psnr)\(step.dropped ? "  DROPPED" : "")\(step.key ? "  key" : "")")
    }
}

func scenario(hevc: Bool, lowLatency: Bool) {
    let name = "\(hevc ? "HEVC" : "H.264") \(lowLatency ? "low-latency RC" : "default RC")"
    print("\n== \(name), \(kbps) kbps, \(width)×\(height)@\(fps)")
    let profile: CFString? = lowLatency ? nil : (hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
    guard let probe = Probe(hevc: hevc, lowLatency: lowLatency, profile: profile) else { return }

    let maxQP = probe.set(kVTCompressionPropertyKey_MaxAllowedFrameQP, 51)
    let minQP = probe.set(kVTCompressionPropertyKey_MinAllowedFrameQP, 0)
    let baseQPSupported = probe.read(kVTCompressionPropertyKey_SupportsBaseFrameQP) as? Bool ?? false
    let hw = probe.read(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? Bool ?? false
    print("    hardware=\(hw) MaxAllowedFrameQP=\(maxQP == noErr ? "ok" : "err \(maxQP)") MinAllowedFrameQP=\(minQP == noErr ? "ok" : "err \(minQP)") SupportsBaseFrameQP=\(baseQPSupported)")

    var last: CVPixelBuffer?
    var steps: [Step] = []
    var offset = 0
    steps.append(run(probe, makeFrame(offset: 0), label: "keyframe", key: true, lastGood: &last))
    if let sample = probe.encode(makeFrame(offset: 0)).sample, let format = CMSampleBufferGetFormatDescription(sample) {
        // That extra frame went to the encoder only; decode it too, so the reference chain holds.
        _ = probe.decode(Encoded(sample: sample))
        print("    bitstream: \(profileLevel(format, hevc: hevc))")
    }
    // Motion: a scroll of 6 px a frame for half a second.
    var motion: [Step] = []
    probe.encodeMs = []
    for _ in 0 ..< 30 {
        offset += 6
        motion.append(run(probe, makeFrame(offset: offset), label: "scroll", lastGood: &last))
    }
    let motionMs = probe.encodeMs.reduce(0, +) / Double(probe.encodeMs.count)
    let still = makeFrame(offset: offset)
    let drops = motion.filter(\.dropped).count
    let avgBytes = motion.map(\.bytes).reduce(0, +) / motion.count
    let avgPSNR = motion.compactMap(\.psnr).reduce(0, +) / Double(max(1, motion.compactMap(\.psnr).count))
    steps.append(Step(label: "30× scroll (avg)", bytes: avgBytes, psnr: avgPSNR, dropped: drops > 0, key: false))
    print("    scroll: \(String(format: "%.1f", motionMs)) ms per frame submit→output, \(drops) dropped")

    // What refreshIfIdle does today: the same frame again, same settings.
    for i in 1 ... 3 { steps.append(run(probe, still, label: "repeat \(i)", lastGood: &last)) }
    // Paint-over A: cap the QP for a few frames.
    let capQP = hevc ? 24 : 22
    let capStatus = probe.set(kVTCompressionPropertyKey_MaxAllowedFrameQP, capQP)
    for i in 1 ... 3 { steps.append(run(probe, still, label: "maxQP \(capQP) #\(i)\(capStatus == noErr ? "" : " (unset!)")", lastGood: &last)) }
    probe.set(kVTCompressionPropertyKey_MaxAllowedFrameQP, 51)
    // Motion again, so the next paint-over has something to repair.
    for _ in 0 ..< 10 {
        offset += 6
        _ = run(probe, makeFrame(offset: offset), label: "", lastGood: &last)
    }
    let still2 = makeFrame(offset: offset)
    steps.append(run(probe, still2, label: "after motion", lastGood: &last))
    // Paint-over B: lift the bitrate cap 4× for a few frames instead.
    probe.set(kVTCompressionPropertyKey_AverageBitRate, kbps * 4000)
    probe.set(kVTCompressionPropertyKey_DataRateLimits, [kbps * 4000 * 3 / 2 / 8, 1] as CFArray)
    for i in 1 ... 3 { steps.append(run(probe, still2, label: "bitrate×4 #\(i)", lastGood: &last)) }
    probe.set(kVTCompressionPropertyKey_AverageBitRate, kbps * 1000)
    probe.set(kVTCompressionPropertyKey_DataRateLimits, [kbps * 1000 * 3 / 2 / 8, 1] as CFArray)
    // Both together, after more motion.
    for _ in 0 ..< 10 {
        offset += 6
        _ = run(probe, makeFrame(offset: offset), label: "", lastGood: &last)
    }
    let still3 = makeFrame(offset: offset)
    steps.append(run(probe, still3, label: "after motion", lastGood: &last))
    probe.set(kVTCompressionPropertyKey_MaxAllowedFrameQP, capQP)
    probe.set(kVTCompressionPropertyKey_AverageBitRate, kbps * 4000)
    probe.set(kVTCompressionPropertyKey_DataRateLimits, [kbps * 4000 * 3 / 2 / 8, 1] as CFArray)
    for i in 1 ... 3 { steps.append(run(probe, still3, label: "maxQP+bitrate #\(i)", lastGood: &last)) }
    show(steps)
    VTCompressionSessionInvalidate(probe.session)
}

/// Whether an explicit level is honoured at this size and rate, or replaced.
func levelCheck() {
    print("\n== H.264 levels at \(width)×\(height)@\(fps)")
    let levels: [(String, CFString)] = [
        ("High_3_1", kVTProfileLevel_H264_High_3_1),
        ("High_5_2", kVTProfileLevel_H264_High_5_2),
        ("High_AutoLevel", kVTProfileLevel_H264_High_AutoLevel),
        ("ConstrainedHigh_AutoLevel", kVTProfileLevel_H264_ConstrainedHigh_AutoLevel),
    ]
    for (name, level) in levels {
        guard let probe = Probe(hevc: false, lowLatency: false, profile: level) else { continue }
        let set = probe.set(kVTCompressionPropertyKey_ProfileLevel, level)
        let encoded = probe.encode(makeFrame(offset: 0), key: true)
        let written = encoded.sample.flatMap(CMSampleBufferGetFormatDescription).map { profileLevel($0, hevc: false) } ?? "no output"
        print("    asked \(name.padding(toLength: 26, withPad: " ", startingAt: 0)) set=\(set == noErr ? "ok" : "err \(set)")  wrote \(written)")
        VTCompressionSessionInvalidate(probe.session)
    }
}

/// Latency of one frame on its own, and throughput with frames queued the way a 60 fps capture
/// feeds them, with and without asking the encoder to favour speed.
func speedCheck(hevc: Bool) {
    let frames = (0 ..< 8).map { makeFrame(offset: $0 * 6) }
    // nil leaves the property unset: the encoder's own default.
    for speed: Bool? in [nil, false, true] {
        guard let probe = Probe(hevc: hevc, lowLatency: false, profile: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel) else { continue }
        let set = speed.map { probe.set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, $0) } ?? noErr
        _ = probe.encode(frames[0], key: true)
        probe.encodeMs = []
        for i in 1 ... 60 { _ = probe.encode(frames[i % frames.count]) }
        let latency = probe.encodeMs.reduce(0, +) / Double(probe.encodeMs.count)
        // Paced: one frame every 1/60 s for two seconds, as a capture delivers them.
        let lock = NSLock()
        var outputs = 0
        let start = Date()
        for i in 0 ..< 2 * fps {
            let due = start.addingTimeInterval(Double(i) / Double(fps))
            let wait = due.timeIntervalSinceNow
            if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
            let pts = CMTime(value: CMTimeValue(1000 + i), timescale: CMTimeScale(fps))
            VTCompressionSessionEncodeFrame(probe.session, imageBuffer: frames[i % frames.count], presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                if status == noErr, sample != nil { lock.lock(); outputs += 1; lock.unlock() }
            }
        }
        VTCompressionSessionCompleteFrames(probe.session, untilPresentationTimeStamp: .invalid)
        let elapsed = Date().timeIntervalSince(start)
        print("    \(hevc ? "HEVC " : "H.264") speedOverQuality=\(speed.map { "\($0)" } ?? "unset")\(set == noErr ? "" : " (err \(set))"): \(String(format: "%.1f", latency)) ms one at a time; paced at \(fps): \(outputs)/\(2 * fps) frames out in \(String(format: "%.2f", elapsed)) s")
        VTCompressionSessionInvalidate(probe.session)
    }
}

var chip = [CChar](repeating: 0, count: 256)
var chipSize = chip.count
sysctlbyname("machdep.cpu.brand_string", &chip, &chipSize, nil, 0)
print("VideoToolbox probe on \(String(cString: chip)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
levelCheck()
print("\n== Encode speed at \(width)×\(height), \(kbps) kbps")
speedCheck(hevc: false)
speedCheck(hevc: true)
scenario(hevc: false, lowLatency: false)
scenario(hevc: true, lowLatency: false)
scenario(hevc: false, lowLatency: true)
scenario(hevc: true, lowLatency: true)
