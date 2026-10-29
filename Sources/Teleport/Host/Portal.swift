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
    private var scale: CGFloat = 2

    /// Called when the window disappears on the host.
    var onGone: ((Portal) -> Void)?

    static func open(window: SCWindow, display: SCDisplay, room: Room) async throws -> Portal {
        guard let app = window.owningApplication else { throw HostError("window has no owning app") }
        let size = Dimensions(width: Int32(window.frame.width * 2), height: Int32(window.frame.height * 2))
        let track = await LocalVideoTrack.createBufferTrack(
            name: TrackName.forWindow(window.windowID),
            source: .screenShareVideo,
            options: BufferCaptureOptions(dimensions: size, fps: 60)
        )
        let portal = Portal(window: window, display: display, app: app, track: track)
        try await portal.startCapture()
        try await portal.publish(to: room)
        portal.startGeometryTracking()
        return portal
    }

    private init(window: SCWindow, display: SCDisplay, app: SCRunningApplication, track: LocalVideoTrack) {
        windowID = window.windowID
        pid = app.processID
        info = WindowCatalog.info(for: window)
        frame = window.frame
        self.display = display
        self.app = app
        self.track = track
        output = FrameOutput(capturer: track.capturer as! BufferCapturer)
    }

    private func startCapture() async throws {
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        scale = CGFloat(filter.pointPixelScale)
        let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
        // WebRTC needs a frame to size the encoder before the track is published.
        try await output.waitForFirstFrame(timeout: 3)
    }

    private func publish(to room: Room) async throws {
        let options = VideoPublishOptions(
            name: TrackName.forWindow(windowID),
            screenShareEncoding: VideoEncoding(maxBitrate: 25_000_000, maxFps: 60),
            simulcast: false,
            preferredCodec: .h264,
            degradationPreference: .maintainResolution
        )
        publication = try await room.localParticipant.publish(videoTrack: track, options: options)
        Log.info("portal \(windowID) published (\(info.app) — \(info.title))")
    }

    func close(room: Room) async {
        geometryTimer?.invalidate()
        geometryTimer = nil
        try? await stream?.stopCapture()
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
        output.refreshIfIdle()
        guard let current = WindowCatalog.currentFrame(of: windowID) else {
            onGone?(self)
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
        } else {
            Task { await moveToNewDisplay() }
        }
    }

    private func moveToNewDisplay() async {
        guard let (_, newDisplay) = try? await WindowCatalog.find(windowID) else { return }
        display = newDisplay
        let filter = SCContentFilter(display: newDisplay, including: [app], exceptingWindows: [])
        scale = CGFloat(filter.pointPixelScale)
        try? await stream?.updateContentFilter(filter)
        try? await stream?.updateConfiguration(makeConfiguration())
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        // sourceRect is in the display's own coordinate space (points, top-left origin).
        let displayFrame = display.frame
        let visible = frame.intersection(displayFrame)
        let rect = (visible.isNull ? frame : visible).offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = max(2, Int((rect.width * scale).rounded()))
        config.height = max(2, Int((rect.height * scale).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 6
        config.capturesAudio = false
        return config
    }
}

/// Receives ScreenCaptureKit frames and feeds them to the LiveKit capturer.
final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "teleport.capture", qos: .userInteractive)
    private let capturer: BufferCapturer
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameAt = Date.distantPast
    private var idleRefreshes = 0
    private var firstFrame: CheckedContinuation<Void, Error>?
    private var hasFrame = false

    init(capturer: BufferCapturer) {
        self.capturer = capturer
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

        capturer.capture(pixelBuffer)
        lastBuffer = pixelBuffer
        lastFrameAt = Date()
        idleRefreshes = 0
        if !hasFrame {
            hasFrame = true
            firstFrame?.resume()
            firstFrame = nil
        }
    }

    /// ScreenCaptureKit stops sending frames when nothing changes. Re-sending the
    /// last frame a few times lets the encoder sharpen a static window.
    func refreshIfIdle() {
        queue.async {
            guard let buffer = self.lastBuffer, self.idleRefreshes < 3,
                  Date().timeIntervalSince(self.lastFrameAt) > 0.4 * Double(self.idleRefreshes + 1)
            else { return }
            self.idleRefreshes += 1
            self.capturer.capture(buffer)
        }
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        Log.warn("capture stopped: \(error)")
    }
}
