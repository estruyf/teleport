import AppKit
import CoreGraphics
import TeleportCore

/// Replays viewer input on this Mac with synthetic CGEvents.
///
/// Events land on whatever is frontmost under the cursor, so the target window is
/// raised and its app activated first. That's fine on a Mac nobody sits at.
@MainActor
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var focusedWindow: CGWindowID?
    private var scrollRemainder = CGPoint.zero

    func handle(_ event: InputEvent, portal: Portal) {
        let point = CGPoint(
            x: portal.frame.minX + event.x * portal.frame.width,
            y: portal.frame.minY + event.y * portal.frame.height
        )
        let flags = CGEventFlags(rawValue: event.flags)

        switch event.kind {
        case .mouseDown, .keyDown:
            ensureFocus(portal)
        case .scroll, .mouseMove, .mouseDrag, .mouseUp, .keyUp:
            break
        }

        switch event.kind {
        case .mouseMove:
            post(mouse: .mouseMoved, at: point, button: .left, flags: flags)
        case .mouseDown, .mouseUp, .mouseDrag:
            let (type, button) = mouseType(for: event)
            post(mouse: type, at: point, button: button, flags: flags, clickCount: event.clickCount)
        case .scroll:
            scroll(event, at: point, flags: flags)
        case .keyDown, .keyUp:
            guard let key = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode, keyDown: event.kind == .keyDown) else { return }
            key.flags = flags
            key.post(tap: .cghidEventTap)
        }
    }

    /// Taps a shortcut on the host, e.g. ⌘N to ask the frontmost app for a new window.
    func pressShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let key = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            key.flags = flags
            key.post(tap: .cghidEventTap)
        }
    }

    private func ensureFocus(_ portal: Portal) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard focusedWindow != portal.windowID || frontmost != portal.pid else { return }
        portal.focus()
        focusedWindow = portal.windowID
    }

    private func mouseType(for event: InputEvent) -> (CGEventType, CGMouseButton) {
        switch (event.button, event.kind) {
        case (0, .mouseDown): (.leftMouseDown, .left)
        case (0, .mouseUp): (.leftMouseUp, .left)
        case (0, _): (.leftMouseDragged, .left)
        case (1, .mouseDown): (.rightMouseDown, .right)
        case (1, .mouseUp): (.rightMouseUp, .right)
        case (1, _): (.rightMouseDragged, .right)
        case (_, .mouseDown): (.otherMouseDown, .center)
        case (_, .mouseUp): (.otherMouseUp, .center)
        default: (.otherMouseDragged, .center)
        }
    }

    private func post(mouse type: CGEventType, at point: CGPoint, button: CGMouseButton, flags: CGEventFlags, clickCount: Int = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = flags
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }

    private func scroll(_ event: InputEvent, at point: CGPoint, flags: CGEventFlags) {
        // Pixel deltas arrive as Doubles; carry the fractions so slow scrolls still move.
        let dx = event.scrollX + scrollRemainder.x
        let dy = event.scrollY + scrollRemainder.y
        let ix = Int32(dx.rounded(.towardZero))
        let iy = Int32(dy.rounded(.towardZero))
        scrollRemainder = CGPoint(x: dx - Double(ix), y: dy - Double(iy))
        guard ix != 0 || iy != 0,
              let wheel = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0)
        else { return }
        wheel.location = point
        wheel.flags = flags
        wheel.post(tap: .cghidEventTap)
    }
}
