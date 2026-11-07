import AppKit
import LiveKit
import TeleportCore

/// One native window showing a remote window's video and forwarding input to it.
///
/// Sharpness: the window's content is kept at exactly the video's pixel size divided by the host's
/// scale, so on a Retina screen every video pixel lands on one screen pixel. Any other size makes
/// the renderer resample, and text goes soft.
@MainActor
final class PortalWindowController: NSWindowController, NSWindowDelegate, TrackDelegate {
    let info: WindowInfo
    private unowned let viewer: ViewerController
    private let portalView: PortalView
    private var resizeDebounce: Timer?
    private var snapTimer: Timer?
    private var hostGone = false
    /// Video pixels per host point; from the host, or worked out from the first frame.
    private var scale: CGFloat?
    /// Set while this window resizes itself to the video, so that isn't sent back as a request.
    private var snapping = false
    private var lastResizeRequest = Date.distantPast

    /// Border colour marking a window as remote; the Dock badge uses the same one.
    static let remoteColor = NSColor.systemTeal

    var trackSid: Track.Sid? { portalView.videoView.track?.sid }

    init(info: WindowInfo, scale: Double?, hostName: String, viewer: ViewerController) {
        self.info = info
        self.viewer = viewer
        self.scale = scale.map { CGFloat($0) }
        portalView = PortalView(windowID: info.id, viewer: viewer)

        let size = NSSize(width: info.width, height: info.height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = info.title.isEmpty ? info.app : "\(info.title) · \(info.app)"
        window.subtitle = "Remote · \(hostName)"
        window.contentView = portalView
        window.center()
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.makeFirstResponder(portalView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // A host window bigger than this screen got squeezed; shrink it on the host to match,
        // or the video is scaled down.
        if let content = window?.contentView?.bounds.size,
           abs(content.width - info.width) > 1 || abs(content.height - info.height) > 1
        {
            requestResize(content)
        }
    }

    func attach(track: RemoteVideoTrack) {
        portalView.videoView.track?.remove(delegate: self)
        portalView.videoView.track = track
        track.add(delegate: self)
        scheduleSnap()
    }

    func hostClosed() {
        hostGone = true
        window?.title = "\(info.title) (ended)"
        close()
    }

    override func close() {
        resizeDebounce?.invalidate()
        snapTimer?.invalidate()
        portalView.releaseHeldKeys()
        portalView.videoView.track?.remove(delegate: self)
        portalView.videoView.track = nil
        super.close()
    }

    // MARK: - Matching the video's size

    nonisolated func track(_: VideoTrack, didUpdateDimensions _: Dimensions?) {
        Task { @MainActor in self.scheduleSnap() }
    }

    /// Waits for the host to settle: a resize just asked for, or a burst of size changes.
    private func scheduleSnap() {
        snapTimer?.invalidate()
        let wait = max(0.25, 0.7 - Date().timeIntervalSince(lastResizeRequest))
        snapTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapToVideo() }
        }
    }

    private func snapToVideo() {
        guard let window, !window.inLiveResize, !(resizeDebounce?.isValid ?? false), !hostGone,
              let dims = portalView.videoView.track?.dimensions, dims.width > 0, dims.height > 0
        else { return }
        let pixels = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        // An older host doesn't say; the first frame of a window this size does.
        let pointScale: CGFloat = self.scale ?? max(1, (pixels.width / info.width).rounded())
        self.scale = pointScale
        let target = CGSize(width: pixels.width / pointScale, height: pixels.height / pointScale)
        guard let current = window.contentView?.bounds.size,
              abs(current.width - target.width) > 0.25 || abs(current.height - target.height) > 0.25
        else { return }
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        // Too big for this screen: leave it, scaled down, rather than hang off the edge.
        if let visible = window.screen?.visibleFrame, newFrame.width > visible.width || newFrame.height > visible.height {
            return
        }
        snapping = true
        defer { snapping = false }
        // Keep the top-left corner where it is, like a window resized by its own app.
        var frame = window.frame
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.setFrame(frame, display: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_: Notification) {
        guard !hostGone else { return }
        viewer.portalClosed(info.id)
    }

    func windowDidResize(_: Notification) {
        guard !snapping, let window, let content = window.contentView?.bounds.size else { return }
        // Ask the host to match our size; while dragging too, debounced.
        resizeDebounce?.invalidate()
        resizeDebounce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestResize(content) }
        }
    }

    func windowDidEndLiveResize(_: Notification) {
        // The app may not take the exact size (a terminal snaps to whole characters); follow it.
        scheduleSnap()
    }

    func windowDidResignKey(_: Notification) {
        // ⌘-Tab away and the key-ups land in another app; don't leave keys held down on the host.
        portalView.releaseHeldKeys()
    }

    func windowDidChangeBackingProperties(_: Notification) {
        scheduleSnap()
    }

    private func requestResize(_ size: CGSize) {
        lastResizeRequest = Date()
        viewer.requestResize(info.id, to: size)
        scheduleSnap()
    }
}

/// Hosts the LiveKit video view and turns local events into `InputEvent`s.
final class PortalView: NSView {
    let videoView = VideoView()
    private let windowID: UInt32
    private unowned let viewer: ViewerController
    private var trackingArea: NSTrackingArea?
    private var lastMove = Date.distantPast
    /// Keys sent down and not yet up, to release when focus moves away.
    private var heldKeys: Set<UInt16> = []

    init(windowID: UInt32, viewer: ViewerController) {
        self.windowID = windowID
        self.viewer = viewer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // The remote border: drawn by this view, so the video sits inside it.
        layer?.borderColor = PortalWindowController.remoteColor.cgColor
        layer?.borderWidth = 3
        videoView.layoutMode = .fit
        registerForDraggedTypes([.fileURL])
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Files dropped on the window go to the host, which drops them into the real window.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let video = videoRect()
        let x = min(max((point.x - video.minX) / video.width, 0), 1)
        let y = min(max(1 - (point.y - video.minY) / video.height, 0), 1)
        for url in urls { viewer.sendFile(url, windowID: windowID, x: x, y: y) }
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // The video is letterboxed inside this view; map to the video's own rectangle.
    private func normalised(_ event: NSEvent) -> (x: Double, y: Double)? {
        let point = convert(event.locationInWindow, from: nil)
        let video = videoRect()
        guard video.width > 0, video.height > 0 else { return nil }
        let x = (point.x - video.minX) / video.width
        let y = 1 - (point.y - video.minY) / video.height // AppKit is bottom-left, host is top-left
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    private func videoRect() -> CGRect {
        guard let dims = videoView.track?.dimensions, dims.width > 0, dims.height > 0 else { return bounds }
        let aspect = CGFloat(dims.width) / CGFloat(dims.height)
        var rect = bounds
        if bounds.width / bounds.height > aspect {
            rect.size.width = bounds.height * aspect
            rect.origin.x = (bounds.width - rect.width) / 2
        } else {
            rect.size.height = bounds.width / aspect
            rect.origin.y = (bounds.height - rect.height) / 2
        }
        return rect
    }

    private func sendMouse(_ kind: InputEvent.Kind, _ event: NSEvent, button: Int = 0) {
        guard let (x, y) = normalised(event) else { return }
        var input = InputEvent(kind: kind, windowID: windowID)
        input.x = x
        input.y = y
        input.button = button
        input.clickCount = event.clickCount
        input.flags = event.modifierFlags.cgFlags
        viewer.send(input)
    }

    override func mouseMoved(with event: NSEvent) {
        // Cap mouse-move traffic to roughly 60/s.
        guard Date().timeIntervalSince(lastMove) > 1.0 / 60 else { return }
        lastMove = Date()
        sendMouse(.mouseMove, event)
    }

    override func mouseDown(with event: NSEvent) { sendMouse(.mouseDown, event) }
    override func mouseUp(with event: NSEvent) { sendMouse(.mouseUp, event) }
    override func mouseDragged(with event: NSEvent) { sendMouse(.mouseDrag, event) }
    override func rightMouseDown(with event: NSEvent) { sendMouse(.mouseDown, event, button: 1) }
    override func rightMouseUp(with event: NSEvent) { sendMouse(.mouseUp, event, button: 1) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(.mouseDrag, event, button: 1) }
    override func otherMouseDown(with event: NSEvent) { sendMouse(.mouseDown, event, button: Int(event.buttonNumber)) }
    override func otherMouseUp(with event: NSEvent) { sendMouse(.mouseUp, event, button: Int(event.buttonNumber)) }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(.mouseDrag, event, button: Int(event.buttonNumber)) }

    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = normalised(event) else { return }
        var input = InputEvent(kind: .scroll, windowID: windowID)
        input.x = x
        input.y = y
        input.flags = event.modifierFlags.cgFlags
        // Line-based wheels report small deltas; scale them up to pixels.
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        input.scrollX = event.scrollingDeltaX * factor
        input.scrollY = event.scrollingDeltaY * factor
        viewer.send(input)
    }

    override func keyDown(with event: NSEvent) { sendKey(.keyDown, event) }
    override func keyUp(with event: NSEvent) { sendKey(.keyUp, event) }

    override func flagsChanged(with event: NSEvent) {
        // Modifier presses arrive here; send them as key events so shift/cmd state matches on the host.
        sendKey(modifierIsDown(event) ? .keyDown : .keyUp, event)
    }

    /// Every shortcut, including ⌘Q and ⌘W, goes to the remote window rather than this app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        sendKey(.keyDown, event)
        // AppKit never delivers the key-up of a ⌘ shortcut. Without one the host sees the key
        // held, and the next press of it can go missing.
        if event.modifierFlags.contains(.command) { sendKey(.keyUp, event) }
        return true
    }

    private func sendKey(_ kind: InputEvent.Kind, _ event: NSEvent) {
        if kind == .keyDown { heldKeys.insert(event.keyCode) } else { heldKeys.remove(event.keyCode) }
        var input = InputEvent(kind: kind, windowID: windowID)
        input.keyCode = event.keyCode
        input.flags = event.modifierFlags.cgFlags
        viewer.send(input)
    }

    /// Sends key-ups for everything still held, modifiers included.
    func releaseHeldKeys() {
        for keyCode in heldKeys {
            var input = InputEvent(kind: .keyUp, windowID: windowID)
            input.keyCode = keyCode
            viewer.send(input)
        }
        heldKeys.removeAll()
    }

    private func modifierIsDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch Int(event.keyCode) {
        case 54, 55: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 57: return flags.contains(.capsLock)
        case 63: return flags.contains(.function)
        default: return false
        }
    }
}

extension NSEvent.ModifierFlags {
    /// The CGEventFlags bits for these modifiers; the two enums share raw values.
    var cgFlags: UInt64 {
        UInt64(intersection(.deviceIndependentFlagsMask).rawValue)
    }
}
