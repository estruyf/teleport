import CoreMedia
import Foundation
import LiveKit
import TeleportCore
import VideoToolbox

/// What the capture side knows about a frame, carried to the encoder on the pixel buffer itself:
/// WebRTC passes the same `CVPixelBuffer` through, and has no other way to say it.
enum FrameKind: Int {
    /// A large part of the window changed.
    case motion
    /// A small change (a caret, a spinner): not enough to hold a paint-over back.
    case change
    /// The last frame again, sent so a viewer that lost a packet or just joined gets a picture.
    case still
    /// The last frame again, to be encoded sharper.
    case paintOver

    private static let key = "TeleportFrameKind" as CFString

    /// Tags a buffer. Buffers come back from ScreenCaptureKit's pool, so every frame sent is tagged.
    func tag(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, Self.key, NSNumber(value: rawValue), .shouldNotPropagate)
    }

    init?(_ buffer: CVPixelBuffer) {
        guard let value = CVBufferCopyAttachment(buffer, Self.key, nil) as? NSNumber else { return nil }
        self.init(rawValue: value.intValue)
    }
}

/// Supplies `TeleportEncoder`s for the codec portals publish with (`video.encoder: teleport`).
///
/// Registered once at launch, before anything else touches the SDK; the SDK refuses afterwards.
/// The SDK's own VideoToolbox encoder stays the fallback for everything else.
final class TeleportEncoderFactory: VideoEncoderFactory {
    private let tuning: VideoTuning

    /// Set once `install(_:)` succeeded; a host started later without a relaunch doesn't have it.
    nonisolated(unsafe) private(set) static var installed = false

    static func install(_ tuning: VideoTuning) {
        do {
            try LiveKitSDK.set(videoEncoderFactory: TeleportEncoderFactory(tuning: tuning))
            installed = true
            Log.info("video: Teleport's own \(tuning.codec.rawValue) encoder is in use")
        } catch {
            Log.warn("video: could not install Teleport's encoder, the SDK's is used: \(error)")
        }
    }

    init(tuning: VideoTuning) {
        self.tuning = tuning
    }

    /// The same formats the SDK's encoder advertises, so the offer doesn't change; only the
    /// codec portals ask for, so the rest stays with the SDK. The level in profile-level-id
    /// doesn't take part in matching; the session picks its own (see `TeleportEncoder`).
    var supportedCodecs: [VideoCodecInfo] {
        switch tuning.codec {
        case .h264:
            ["640c1f", "42e01f"].map {
                VideoCodecInfo(name: "H264", parameters: ["profile-level-id": $0, "level-asymmetry-allowed": "1", "packetization-mode": "1"])
            }
        case .h265:
            [VideoCodecInfo(name: "H265")]
        }
    }

    func createEncoder(for codec: VideoCodecInfo) -> (any VideoEncoder)? {
        TeleportEncoder(codec: codec, tuning: tuning)
    }
}

/// An H.264/H.265 encoder on a `VTCompressionSession` of our own, so the rate control can change
/// per frame: frames tagged `.paintOver` are encoded with a QP ceiling and more bits.
///
/// Measured with scripts/vt-probe.swift: a QP ceiling alone barely moves the picture, because the
/// bitrate cap still binds; a ceiling together with a raised bitrate gains 2–5 dB on a still
/// screen. Real-time, no frame reordering, Constrained High (or Constrained Baseline when that
/// was negotiated) or Main at AutoLevel: VideoToolbox refuses explicit levels up to 5.2 at
/// 3840×2400@60, which needs 6.0.
final class TeleportEncoder: VideoEncoder, @unchecked Sendable {
    let implementationName = "Teleport/VideoToolbox"

    private let codec: VideoCodecInfo
    private let tuning: VideoTuning
    private let hevc: Bool
    private let lock = NSLock()

    // Guarded by `lock`. Never held while the callback runs: WebRTC packetizes and sends inside it.
    private var session: VTCompressionSession?
    private var callback: VideoEncoderCallback?
    private var width = 0
    private var height = 0
    private var targetKbps: UInt32 = 2500
    private var framerate: UInt32 = 60
    /// What the session is set to now, so properties are only touched when they change.
    private var applied: (kbps: UInt32, paintOver: Bool)?
    /// Still frames to sharpen after a keyframe: it is squeezed into the normal budget.
    private var sharpenAfterKey = 0
    private var stats = Stats()

    private struct Stats {
        var since = Date()
        var frames = 0
        var bytes = 0
        var paintOverFrames = 0
        var paintOverBytes = 0
        var drops = 0
        var encodeSeconds = 0.0
    }

    init(codec: VideoCodecInfo, tuning: VideoTuning) {
        self.codec = codec
        self.tuning = tuning
        hevc = codec.name.uppercased() == "H265"
    }

    func setCallback(_ callback: VideoEncoderCallback?) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func startEncode(with settings: VideoEncoderSettings, numberOfCores _: Int) -> VideoEncoderStatus {
        lock.lock()
        defer { lock.unlock() }
        targetKbps = max(settings.startBitrateKbps, 300)
        framerate = max(settings.maxFramerate, 1)
        return makeSession(width: Int(settings.dimensions.width), height: Int(settings.dimensions.height)) ? .ok : .error
    }

    func setBitrate(_ bitrateKbps: UInt32, framerate: UInt32) -> VideoEncoderStatus {
        lock.lock()
        defer { lock.unlock() }
        // 0 means WebRTC paused the stream; keep the last target for when it resumes.
        if bitrateKbps > 0 { targetKbps = bitrateKbps }
        if framerate > 0, framerate != self.framerate {
            self.framerate = framerate
            if let session { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: framerate as CFNumber) }
        }
        if let applied { applyRate(paintOver: applied.paintOver) }
        return .ok
    }

    func encode(_ frame: VideoFrame, frameTypes: [EncodedVideoFrame.FrameType]) -> VideoEncoderStatus {
        guard let pixelBuffer = (frame.buffer as? CVPixelVideoBuffer)?.pixelBuffer else { return .error }
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)

        lock.lock()
        // WebRTC restarts the encoder when the window resizes; a frame that still differs
        // gets a session of its own size rather than a scaled picture.
        if session == nil || frameWidth != width || frameHeight != height {
            guard makeSession(width: frameWidth, height: frameHeight) else {
                lock.unlock()
                return .error
            }
        }
        guard let session else {
            lock.unlock()
            return .uninitialized
        }
        let kind = FrameKind(pixelBuffer)
        var paintOver = false
        if tuning.paintOver {
            switch kind {
            case .paintOver:
                paintOver = true
                sharpenAfterKey = 0
            case .still where sharpenAfterKey > 0:
                sharpenAfterKey -= 1
                paintOver = true
            case .motion:
                // A keyframe in the middle of motion: the paint-over after the motion covers it.
                sharpenAfterKey = 0
            default:
                break
            }
        }
        // WebRTC doesn't wait for one frame before sending the next. A frame still inside
        // VideoToolbox when the settings change could be encoded with the wrong ones: a motion
        // frame at paint-over size is a latency spike. So the session is flushed first, only when
        // paint-over starts or ends; at the start nothing is in flight (the window was still).
        // Outside the lock, because the output handler takes it.
        if let applied, applied.paintOver != paintOver {
            lock.unlock()
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            lock.lock()
        }
        applyRate(paintOver: paintOver)
        lock.unlock()

        let properties = frameTypes.contains(.key) ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let rtpTimestamp = frame.rtpTimestamp
        let dimensions = Dimensions(width: Int32(frameWidth), height: Int32(frameHeight))
        let submitted = Date()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000),
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sample in
            self?.deliver(status: status, flags: flags, sample: sample, rtpTimestamp: rtpTimestamp,
                          dimensions: dimensions, paintOver: paintOver, submitted: submitted)
        }
        return status == noErr ? .ok : .error
    }

    func releaseEncoder() -> VideoEncoderStatus {
        lock.lock()
        let session = self.session
        self.session = nil
        applied = nil
        lock.unlock()
        // Flush first, outside the lock: the output handler takes it to find the callback.
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        lock.lock()
        callback = nil
        lock.unlock()
        return .ok
    }

    // MARK: - Session

    /// Call with `lock` held.
    private func makeSession(width: Int, height: Int) -> Bool {
        if let old = session {
            VTCompressionSessionInvalidate(old)
            session = nil
        }
        applied = nil
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            Log.error("video: VTCompressionSessionCreate \(width)x\(height) failed: \(status)")
            return false
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            let status = VTSessionSetProperty(created, key: key, value: value)
            if status != noErr { Log.warn("video: encoder property \(key) not taken: \(status)") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        if hevc {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        } else if codec.parameters["profile-level-id"]?.lowercased().hasPrefix("42") == true {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
        } else {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        }
        // Keyframes only when WebRTC asks (a viewer joined or lost packets), as the SDK's encoder does.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 240 as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, framerate as CFNumber)
        // On an M2 Pro, HEVC at 3840×2400 takes 13 ms a frame with this and 23 ms without.
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, tuning.prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        self.width = width
        self.height = height
        applyRate(paintOver: false)
        Log.info("video: \(hevc ? "HEVC" : "H.264") session \(width)x\(height) at \(targetKbps) kbps")
        return true
    }

    /// The bitrate WebRTC asked for, and for paint-over frames a multiple of it and a QP ceiling.
    /// The overshoot is short: paint-overs follow a still second, when frames cost next to nothing.
    /// Call with `lock` held.
    private func applyRate(paintOver: Bool) {
        guard let session else { return }
        let kbps = paintOver ? UInt32(Double(targetKbps) * tuning.paintOverBitrateBoost) : targetKbps
        if applied?.kbps != kbps {
            let bps = Int(kbps) * 1000
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
            // As the SDK's encoder: at most 1.5× the average in any one second.
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bps * 3 / 2 / 8, 1] as CFArray)
        }
        if applied?.paintOver != paintOver, applied != nil || paintOver {
            let qp: CFNumber? = paintOver ? tuning.paintOverMaxQP as CFNumber : nil
            let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: qp)
            if status != noErr, !paintOver {
                // No way to clear it: the highest QP there is means no ceiling.
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: 51 as CFNumber)
            } else if status != noErr {
                Log.warn("video: this encoder takes no QP ceiling (\(status)); paint-overs only raise the bitrate")
            }
        }
        applied = (kbps, paintOver)
    }

    // MARK: - Output

    private func deliver(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?, rtpTimestamp: UInt32,
                         dimensions: Dimensions, paintOver: Bool, submitted: Date)
    {
        guard status == noErr, !flags.contains(.frameDropped), let sample,
              let data = AnnexB.data(sample, hevc: hevc)
        else {
            lock.lock()
            stats.drops += 1
            lock.unlock()
            return
        }
        let keyframe = AnnexB.isKeyframe(sample)
        lock.lock()
        if keyframe, tuning.paintOver { sharpenAfterKey = tuning.paintOverFrames }
        let callback = self.callback
        let line = noteStats(bytes: data.count, paintOver: paintOver, seconds: Date().timeIntervalSince(submitted))
        lock.unlock()
        _ = callback?(EncodedVideoFrame(data: data, dimensions: dimensions, rtpTimestamp: rtpTimestamp, frameType: keyframe ? .key : .delta))
        if let line { StatsLog.write(line) }
    }

    /// A stats.log line once a second, with what WebRTC can't see: paint-overs and VideoToolbox's own drops.
    /// Call with `lock` held.
    private func noteStats(bytes: Int, paintOver: Bool, seconds: Double) -> String? {
        stats.frames += 1
        stats.bytes += bytes
        stats.encodeSeconds += seconds
        if paintOver {
            stats.paintOverFrames += 1
            stats.paintOverBytes += bytes
        }
        let elapsed = Date().timeIntervalSince(stats.since)
        guard tuning.stats, elapsed >= 1 else { return nil }
        defer { stats = Stats() }
        return "encoder \(width)x\(height) frames=\(stats.frames) kbps=\(Int(Double(stats.bytes) * 8 / elapsed / 1000)) target=\(targetKbps)"
            + " paintover=\(stats.paintOverFrames)/\(stats.paintOverBytes / 1024)KB vt_drops=\(stats.drops)"
            + " vt_ms=\(String(format: "%.1f", stats.encodeSeconds / Double(stats.frames) * 1000))"
    }
}

/// VideoToolbox writes length-prefixed NAL units (AVCC/HVCC); WebRTC's packetizers want start codes.
enum AnnexB {
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first
        else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// The frame as Annex B, with the parameter sets in front of a keyframe.
    static func data(_ sample: CMSampleBuffer, hevc: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample)
        else { return nil }
        var out = Data()
        var headerLength: Int32 = 4
        var count = 0
        func parameterSet(_ index: Int) -> (UnsafePointer<UInt8>, Int)? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            guard status == noErr, let pointer else { return nil }
            return (pointer, size)
        }
        // Index 0 also reports the count and the NAL length size.
        guard let first = parameterSet(0) else { return nil }
        if isKeyframe(sample) {
            out.append(contentsOf: startCode)
            out.append(first.0, count: first.1)
            for index in 1 ..< max(count, 1) {
                guard let (pointer, size) = parameterSet(index) else { return nil }
                out.append(contentsOf: startCode)
                out.append(pointer, count: size)
            }
        }
        // The block buffer need not be contiguous; copy it out.
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        let prefix = Int(headerLength)
        var offset = 0
        while offset + prefix <= length {
            var nalLength = 0
            for i in 0 ..< prefix { nalLength = nalLength << 8 | Int(bytes[offset + i]) }
            offset += prefix
            guard nalLength > 0, offset + nalLength <= length else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[offset ..< offset + nalLength])
            offset += nalLength
        }
        return out
    }
}
