import AppKit
import ApplicationServices
import CPrivate
import ScreenCaptureKit
import TeleportCore

/// Lists shareable windows and finds them again by ID.
enum WindowCatalog {
    static func list(allowedApps: [String]) async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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
