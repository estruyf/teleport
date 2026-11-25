import AppKit
import LiveKit
import ScreenCaptureKit
import TeleportCore

/// Streams one window to the room as its own video track.
///
/// It captures the whole owning app, cropped to the window's frame, so menus,
/// dropdowns and autocomplete popups (separate windows) show up too.
@MainActor
final class Portal: NSObject {
    let windowID: CGWindowID
    let pid: pid_t
    private(set) var info: WindowInfo
    private(set) var frame: CGRect
    private var display: SCDisplay
    private let app: SCRunningApplication
    private var stream: SCStream?
    private let output: FrameOutput
    private let track: LocalVideoTrack
    private var publication: LocalTrackPublication?
    private var geometryTimer: Timer?
    /// Video pixels per window point.
    private(set) var scale: CGFloat = 2
    /// Closed, or the window went away; nothing may restart it.
    private var gone = false
    private var movingDisplay = false
    private var restarts = 0
    private var lastRestart = Date.distantPast
    private let tuning: VideoTuning
    /// Held here: the SDK keeps track delegates weakly.
    private var statsReporter: TrackStatsReporter?

    /// Called when the window disappears on the host.
    var onGone: ((Portal) -> Void)?

    static func open(window: SCWindow, display: SCDisplay, room: Room, tuning: VideoTuning) async throws -> Portal {
        guard let app = window.owningApplication else { throw HostError("window has no owning app") }
        let size = Dimensions(width: Int32(window.frame.width * 2), height: Int32(window.frame.height * 2))
        let track = await LocalVideoTrack.createBufferTrack(
            name: TrackName.forWindow(window.windowID),
            source: .screenShareVideo,
            options: BufferCaptureOptions(dimensions: size, fps: 60),
            reportStatistics: tuning.stats
        )
        let portal = Portal(window: window, display: display, app: app, track: track, tuning: tuning)
        do {
            try await portal.startCapture()
            try await portal.publish(to: room)
        } catch {
            // A stream that started but never delivered a frame would otherwise capture forever.
            await portal.close(room: room)
            throw error
        }
        portal.startGeometryTracking()
        return portal
    }

    private init(window: SCWindow, display: SCDisplay, app: SCRunningApplication, track: LocalVideoTrack, tuning: VideoTuning) {
        windowID = window.windowID
        pid = app.processID
        self.tuning = tuning
        info = WindowCatalog.info(for: window)
        frame = window.frame
        self.display = display
        self.app = app
        self.track = track
        output = FrameOutput(capturer: track.capturer as! BufferCapturer, paintOver: tuning.paintOver ? PaintOverPlan(tuning) : nil, windowID: window.windowID)
        super.init()
        if tuning.stats {
            let reporter = TrackStatsReporter(role: "host", label: "win=\(window.windowID)")
            if tuning.paintOver { reporter.extra = { [output] in output.takeCounts() } }
            track.add(delegate: reporter)
            statsReporter = reporter
        }
        output.onStop = { [weak self] error in
            Task { @MainActor in self?.captureStopped(error) }
        }
    }

    private func startCapture() async throws {
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        scale = CGFloat(filter.pointPixelScale)
        if scale < 2 {
            Log.warn("portal \(windowID) captures at \(scale)x, so it looks soft on a Retina viewer; the virtual display renders at 2x")
        }
        let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.start()
        self.stream = stream
        // WebRTC needs a frame to size the encoder before the track is published.
        try await output.waitForFirstFrame(timeout: 3)
    }

    /// ScreenCaptureKit gave up on the stream (the display changed or slept, say). Without a
    /// restart the viewer keeps the last frame forever; after a few failed tries the portal closes.
    private func captureStopped(_ error: Error) {
        guard !gone, stream != nil else { return }
        stream = nil
        if Date().timeIntervalSince(lastRestart) > 60 { restarts = 0 }
        restarts += 1
        lastRestart = Date()
        guard restarts <= 3 else {
            Log.warn("portal \(windowID) capture keeps stopping; closing it")
            markGone()
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(restarts) * 1_000_000_000)
            guard !gone else { return }
            do {
                let (_, newDisplay) = try await WindowCatalog.find(windowID)
                display = newDisplay
                try await startCapture()
                if gone {
                    // Closed while restarting.
                    try? await stream?.stop()
                    stream = nil
                    return
                }
                Log.info("portal \(windowID) capture restarted")
            } catch {
                Log.warn("portal \(windowID) capture restart failed: \(error)")
                markGone()
            }
        }
    }

    private func markGone() {
        guard !gone else { return }
        gone = true
        onGone?(self)
    }

    private func publish(to room: Room) async throws {
        let options = VideoPublishOptions(
            name: TrackName.forWindow(windowID),
            screenShareEncoding: VideoEncoding(maxBitrate: tuning.maxBitrateKbps * 1000, maxFps: 60),
            simulcast: false,
            // When the SFU or the viewer won't take H.265, WebRTC negotiates the next codec it
            // offers instead; stats.log shows which one it was.
            preferredCodec: tuning.codec == .h265 ? .h265 : .h264,
            degradationPreference: tuning.degradation == .maintainFramerateAndResolution ? .maintainFramerateAndResolution : .maintainResolution
        )
        publication = try await room.localParticipant.publish(videoTrack: track, options: options)
        Log.info("portal \(windowID) published (\(info.app) — \(info.title))")
    }

    func close(room: Room) async {
        gone = true
        geometryTimer?.invalidate()
        geometryTimer = nil
        try? await stream?.stop()
        stream = nil
        if let publication {
            try? await room.localParticipant.unpublish(publication: publication)
        }
        publication = nil
        Log.info("portal \(windowID) closed")
    }

    /// Resizes the real window; the geometry timer picks up the new frame.
    func resize(to size: CGSize) {
        AXWindow.setSize(pid: pid, windowID: windowID, size: size)
        refreshGeometry()
    }

    func focus() {
        AXWindow.focus(pid: pid, windowID: windowID)
    }

    // MARK: - Geometry

    private func startGeometryTracking() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGeometry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        geometryTimer = timer
    }

    private func refreshGeometry() {
        guard !gone else { return }
        output.refreshIfIdle()
        guard let current = WindowCatalog.currentFrame(of: windowID) else {
            markGone()
            return
        }
        guard current != frame else { return }
        frame = current
        info.width = current.width
        info.height = current.height

        if display.frame.contains(CGPoint(x: current.midX, y: current.midY)) {
            stream?.updateConfiguration(makeConfiguration()) { error in
                if let error { Log.warn("portal update failed: \(error)") }
            }
        } else if !movingDisplay {
            Task { await moveToNewDisplay() }
        }
    }

    private func moveToNewDisplay() async {
        movingDisplay = true
        defer { movingDisplay = false }
        guard let (_, newDisplay) = try? await WindowCatalog.find(windowID) else { return }
        display = newDisplay
        let filter = SCContentFilter(display: newDisplay, including: [app], exceptingWindows: [])
        scale = CGFloat(filter.pointPixelScale)
        try? await stream?.update(filter: filter)
        try? await stream?.update(configuration: makeConfiguration())
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        // sourceRect is in the display's own coordinate space (points, top-left origin).
        let displayFrame = display.frame
        let visible = frame.intersection(displayFrame)
        let rect = (visible.isNull ? frame : visible).offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        // Even sizes: the H.264 encoder crops odd ones, and the viewer would then scale by a hair.
        config.width = max(2, Int((rect.width * scale).rounded()) & ~1)
        config.height = max(2, Int((rect.height * scale).rounded()) & ~1)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 6
        config.capturesAudio = false
        return config
    }
}

/// When and how a portal paints over (`video.paintOver`).
struct PaintOverPlan {
    var delay: TimeInterval
    var frames: Int
    var motionMinArea: Double
    /// Between the frames of one paint-over: two frame times, so WebRTC's 60 fps limit doesn't drop one.
    var spacing: TimeInterval = 2.0 / 60
    /// Small changes alone (typing, a spinner) repaint at most this often; motion repaints as soon as it stops.
    var smallChangeInterval: TimeInterval = 1

    init(_ tuning: VideoTuning) {
        delay = Double(tuning.paintOverDelayMs) / 1000
        frames = tuning.paintOverFrames
        motionMinArea = tuning.motionMinArea
    }
}

/// Receives ScreenCaptureKit frames and feeds them to the LiveKit capturer.
///
/// With a paint-over plan it also tells motion from small changes, by how much of the frame
/// ScreenCaptureKit marks dirty, and once the window has held still it re-sends the last frame a
/// few times tagged `.paintOver`; `TeleportEncoder` encodes those sharper.
final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "teleport.capture", qos: .userInteractive)
    private let capturer: BufferCapturer
    private let paintOver: PaintOverPlan?
    private let windowID: CGWindowID
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameAt = Date.distantPast
    private var lastRefreshAt = Date.distantPast
    private var idleRefreshes = 0
    /// ScreenCaptureKit stopped the stream on its own. Called on `queue`.
    var onStop: ((Error) -> Void)?
    private var firstFrame: CheckedContinuation<Void, Error>?
    private var hasFrame = false

    // Paint-over state, on `queue`.
    private var lastMotionAt = Date.distantPast
    private var lastBurstAt = Date.distantPast
    private var lastPaintOverFrameAt = Date.distantPast
    private var motionSinceBurst = false
    private var changedSinceBurst = false
    private var burstLeft = 0
    /// When the pending check fires; a newer, earlier one replaces it.
    private var checkAt: Date?
    private var checkGeneration = 0
    private var dirtyRectSamples = 0
    /// For stats.log; read from the stats reporter's thread.
    private let countsLock = NSLock()
    private var counts = (motion: 0, change: 0, paintOver: 0)

    init(capturer: BufferCapturer, paintOver: PaintOverPlan? = nil, windowID: CGWindowID = 0) {
        self.capturer = capturer
        self.paintOver = paintOver
        self.windowID = windowID
    }

    func waitForFirstFrame(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.hasFrame { return continuation.resume() }
                self.firstFrame = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.firstFrame?.resume(throwing: HostError("no frames captured within \(timeout)s"))
                    self.firstFrame = nil
                }
            }
        }
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        if let paintOver, let info = attachments.first {
            let kind: FrameKind = changedShare(info, pixelBuffer) >= paintOver.motionMinArea ? .motion : .change
            kind.tag(pixelBuffer)
            noteChange(kind)
        }
        capturer.capture(pixelBuffer)
        lastBuffer = pixelBuffer
        lastFrameAt = Date()
        idleRefreshes = 0
        if !hasFrame {
            hasFrame = true
            firstFrame?.resume()
            firstFrame = nil
        }
        if paintOver != nil { schedulePaintOverCheck() }
    }

    /// ScreenCaptureKit stops sending frames when nothing changes. Keep re-sending the last one:
    /// a quick burst so the encoder sharpens a static window, then once a second, so a viewer that
    /// lost a packet or just subscribed gets a fresh keyframe instead of a frozen or blurry picture.
    /// A paint-over replaces the quick burst.
    func refreshIfIdle() {
        queue.async {
            let now = Date()
            let interval = self.idleRefreshes < 8 && self.paintOver == nil ? 0.2 : 1.0
            guard let buffer = self.lastBuffer,
                  now.timeIntervalSince(self.lastFrameAt) > 0.2,
                  now.timeIntervalSince(self.lastRefreshAt) >= interval,
                  self.burstLeft == 0
            else { return }
            self.idleRefreshes += 1
            self.lastRefreshAt = now
            // The buffer may still carry the tag of the last paint-over.
            if self.paintOver != nil { FrameKind.still.tag(buffer) }
            self.capturer.capture(buffer)
        }
    }

    /// Stats.log's view of the capture: frames of each kind since the last call.
    func takeCounts() -> String {
        countsLock.lock()
        defer { countsLock.unlock() }
        defer { counts = (0, 0, 0) }
        return "cap_motion=\(counts.motion) cap_change=\(counts.change) cap_paintover=\(counts.paintOver)"
    }

    // MARK: - Paint-over

    /// Share of the frame ScreenCaptureKit marked as changed (0–1). No list means it doesn't
    /// know, so that counts as everything. The rects are in pixels (SCStream.h); the header says
    /// NSValue, other code reads CGRect dictionaries, so both are taken.
    private func changedShare(_ info: [SCStreamFrameInfo: Any], _ buffer: CVPixelBuffer) -> Double {
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard let list = info[.dirtyRects] as? [Any] else { return 1 }
        let rects = list.compactMap { item -> CGRect? in
            if let value = item as? NSValue, !(item is NSDictionary) { return value.rectValue }
            return (item as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
        // The first few, in the log, to check the rects are in this buffer's pixels.
        if dirtyRectSamples < 3, !rects.isEmpty {
            dirtyRectSamples += 1
            let content = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            Log.info("portal \(windowID) dirty rects \(rects.prefix(4).map { "\($0)" }.joined(separator: " ")) in \(Int(bounds.width))x\(Int(bounds.height)), content \(content.map { "\($0)" } ?? "?")")
        }
        let area = rects.reduce(0.0) { sum, rect in
            let visible = rect.intersection(bounds)
            return visible.isNull ? sum : sum + Double(visible.width * visible.height)
        }
        return min(1, area / Double(max(1, bounds.width * bounds.height)))
    }

    private func noteChange(_ kind: FrameKind) {
        countsLock.lock()
        if kind == .motion { counts.motion += 1 } else { counts.change += 1 }
        countsLock.unlock()
        if kind == .motion {
            lastMotionAt = Date()
            motionSinceBurst = true
            // Moving again: a paint-over now would be wasted on a picture about to change.
            burstLeft = 0
        }
        changedSinceBurst = true
    }

    /// When the next paint-over frame may go out.
    private func nextPaintOver(_ plan: PaintOverPlan) -> Date {
        if burstLeft > 0 { return lastPaintOverFrameAt.addingTimeInterval(plan.spacing) }
        var due = lastMotionAt.addingTimeInterval(plan.delay)
        if !motionSinceBurst { due = max(due, lastBurstAt.addingTimeInterval(plan.smallChangeInterval)) }
        return due
    }

    private func schedulePaintOverCheck() {
        guard let plan = paintOver, changedSinceBurst || burstLeft > 0 else { return }
        let due = nextPaintOver(plan)
        // A check already due sooner covers this one. One due later (a small change waiting out
        // its interval) must not hold back the paint-over after motion that just stopped.
        if let checkAt, checkAt <= due { return }
        checkAt = due
        checkGeneration += 1
        let generation = checkGeneration
        queue.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow)) { [weak self] in
            guard let self, generation == self.checkGeneration else { return }
            self.checkAt = nil
            self.paintOverTick()
        }
    }

    private func paintOverTick() {
        guard let plan = paintOver, let buffer = lastBuffer else { return }
        if burstLeft == 0 {
            guard changedSinceBurst else { return }
            guard Date() >= nextPaintOver(plan) else { return schedulePaintOverCheck() }
            burstLeft = plan.frames
            changedSinceBurst = false
            motionSinceBurst = false
            lastBurstAt = Date()
        } else if Date() < nextPaintOver(plan) {
            return schedulePaintOverCheck()
        }
        FrameKind.paintOver.tag(buffer)
        capturer.capture(buffer)
        burstLeft -= 1
        lastPaintOverFrameAt = Date()
        countsLock.lock()
        counts.paintOver += 1
        countsLock.unlock()
        schedulePaintOverCheck()
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        Log.warn("capture stopped: \(error)")
        queue.async { self.onStop?(error) }
    }
}
