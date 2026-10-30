import AppKit
import ApplicationServices
import CPrivate
import ScreenCaptureKit
import os
import TeleportCore

/// ScreenCaptureKit can call a completion handler twice. Swift's generated async wrappers
/// (`try await stream.startCapture()` and friends) can't survive that: the second call resumes a
/// continuation whose task already moved on, and the host dies with EXC_BAD_ACCESS in
/// CheckedContinuation.resume on an SCK queue. Seen after pairing (shareable content) and when
/// opening a portal (SCStream.startCapture). So every SCK call goes through the completion-handler
/// API here, which keeps the first answer and drops the rest.
func screenCaptureKit<T>(
    _ what: String,
    isolation _: isolated (any Actor)? = #isolation,
    _ call: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let answered = OSAllocatedUnfairLock(initialState: false)
        call { result in
            let first = answered.withLock { done in
                defer { done = true }
                return !done
            }
            guard first else {
                Log.warn("ScreenCaptureKit answered \(what) twice; ignoring the second")
                return
            }
            continuation.resume(with: result)
        }
    }
}

extension SCStream {
    func start() async throws {
        try await screenCaptureKit("startCapture") { done in startCapture { done($0.map(Result.failure) ?? .success(())) } }
    }

    func stop() async throws {
        try await screenCaptureKit("stopCapture") { done in stopCapture { done($0.map(Result.failure) ?? .success(())) } }
    }

    func update(filter: SCContentFilter) async throws {
        try await screenCaptureKit("updateContentFilter") { done in
            updateContentFilter(filter) { done($0.map(Result.failure) ?? .success(())) }
        }
    }

    func update(configuration: SCStreamConfiguration) async throws {
        try await screenCaptureKit("updateConfiguration") { done in
            updateConfiguration(configuration) { done($0.map(Result.failure) ?? .success(())) }
        }
    }
}

/// Overlapping shareable-content requests make the double answers above much more likely (the
/// app list, window lookups and portal tracking all asked at once right after a viewer paired).
/// So: one request at a time, and callers that arrive while one is running share its result.
actor ShareableContent {
    static let shared = ShareableContent()
    private var pending: Task<SCShareableContent, Error>?

    func fetch() async throws -> SCShareableContent {
        if let pending { return try await pending.value }
        let task = Task { try await Self.request() }
        pending = task
        defer { pending = nil }
        return try await task.value
    }

    private static func request() async throws -> SCShareableContent {
        try await screenCaptureKit("a shareable-content request") { done in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                done(content.map(Result.success) ?? .failure(error ?? HostError("ScreenCaptureKit returned no shareable content")))
            }
        }
    }
}

/// Lists shareable windows and finds them again by ID.
enum WindowCatalog {
    static func list(allowedApps: [String]) async throws -> [WindowInfo] {
        let content = try await ShareableContent.shared.fetch()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows
            .filter { window in
                guard let app = window.owningApplication, app.processID != ownPID else { return false }
                guard window.windowLayer == 0, window.frame.width >= 80, window.frame.height >= 60 else { return false }
                return allowedApps.contains(app.bundleIdentifier)
            }
            .map(info(for:))
            .sorted { ($0.app, $0.title) < ($1.app, $1.title) }
    }

    static func find(_ id: CGWindowID) async throws -> (SCWindow, SCDisplay) {
        var content = try await ShareableContent.shared.fetch()
        // A window that just opened can take ScreenCaptureKit a moment to list.
        for _ in 0 ..< 6 where !content.windows.contains(where: { $0.windowID == id }) {
            guard WindowCatalog.currentFrame(of: id) != nil else { break }
            try await Task.sleep(nanoseconds: 500_000_000)
            content = try await ShareableContent.shared.fetch()
        }
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw HostError("window \(id) is not on screen")
        }
        guard let display = display(containing: window.frame, in: content.displays) else {
            throw HostError("window \(id) is not on any display")
        }
        return (window, display)
    }

    static func display(containing frame: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.first { $0.frame.contains(center) }
            ?? displays.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
    }

    static func info(for window: SCWindow) -> WindowInfo {
        WindowInfo(
            id: window.windowID,
            app: window.owningApplication?.applicationName ?? "?",
            bundleID: window.owningApplication?.bundleIdentifier ?? "",
            title: window.title ?? "",
            width: window.frame.width,
            height: window.frame.height
        )
    }

    /// Current frame in global points (top-left origin), or nil when the window is gone.
    static func currentFrame(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = list.first,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
}

/// Accessibility helpers: raise, focus, resize and move windows owned by other apps.
enum AXWindow {
    static func element(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        return windows.first { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == windowID
        }
    }

    static func focus(pid: pid_t, windowID: CGWindowID) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = element(pid: pid, windowID: windowID) {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    static func setSize(pid: pid_t, windowID: CGWindowID, size: CGSize) {
        guard let window = element(pid: pid, windowID: windowID) else { return }
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    static func setPosition(pid: pid_t, windowID: CGWindowID, origin: CGPoint) {
        guard let window = element(pid: pid, windowID: windowID) else { return }
        var origin = origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
