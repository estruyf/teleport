import AppKit
import LiveKit
import TeleportCore

/// One native window showing a remote window's video and forwarding input to it.
@MainActor
final class PortalWindowController: NSWindowController, NSWindowDelegate {
    let info: WindowInfo
    private unowned let viewer: ViewerController
    private let portalView: PortalView
    private var resizeDebounce: Timer?
    private var hostGone = false

    /// Border colour marking a window as remote; the Dock badge uses the same one.
    static let remoteColor = NSColor.systemTeal

    init(info: WindowInfo, hostName: String, viewer: ViewerController) {
        self.info = info
        self.viewer = viewer
        portalView = PortalView(windowID: info.id, viewer: viewer)

        let size = NSSize(width: info.width, height: info.height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = info.title.isEmpty ? info.app : "\(info.title) — \(info.app)"
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

    func attach(track: RemoteVideoTrack) {
        portalView.videoView.track = track
    }

    func hostClosed() {
        hostGone = true
        window?.title = "\(info.title) (ended)"
        portalView.videoView.track = nil
        close()
    }

    override func close() {
        portalView.videoView.track = nil
        super.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_: Notification) {
        guard !hostGone else { return }
        viewer.portalClosed(info.id)
    }

    func windowDidResize(_: Notification) {
        guard let window, let content = window.contentView?.bounds.size else { return }
        // Ask the host to match our size once the user stops dragging.
        resizeDebounce?.invalidate()
        resizeDebounce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.viewer.requestResize(self.info.id, to: content)
            }
        }
    }
}

/// Hosts the LiveKit video view and turns local events into `InputEvent`s.
final class PortalView: NSView {
    let videoView = VideoView()
    private let windowID: UInt32
    private unowned let viewer: ViewerController
    private var trackingArea: NSTrackingArea?
    private var lastMove = Date.distantPast

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
        let flags = event.modifierFlags.cgFlags
        var input = InputEvent(kind: modifierIsDown(event) ? .keyDown : .keyUp, windowID: windowID)
        input.keyCode = event.keyCode
        input.flags = flags
        viewer.send(input)
    }

    /// Every shortcut, including ⌘Q and ⌘W, goes to the remote window rather than this app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        sendKey(.keyDown, event)
        return true
    }

    private func sendKey(_ kind: InputEvent.Kind, _ event: NSEvent) {
        var input = InputEvent(kind: kind, windowID: windowID)
        input.keyCode = event.keyCode
        input.flags = event.modifierFlags.cgFlags
        viewer.send(input)
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
