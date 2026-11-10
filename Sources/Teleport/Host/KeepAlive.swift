import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import TeleportCore

/// Keeps this Mac counting as in use, so a policy that locks it after some idle minutes
/// (a screen saver with a password, or one set by the company's device management) never fires.
///
/// Those timers read the HID idle time, which only real or synthetic input resets. Power
/// assertions don't: `ProcessInfo.beginActivity` keeps the display on but the idle time still
/// climbs, and so does `IOPMAssertionDeclareUserActivity` (what `caffeinate -u` uses). A mouse
/// move to where the pointer already is does reset it, and nothing on screen moves.
/// Posting it needs Accessibility, which hosting needs anyway.
@MainActor
final class KeepAlive {
    /// Lock policies start at one minute; stay well below that.
    static let idleThreshold: TimeInterval = 30
    private var timer: Timer?
    private var assertion = IOPMAssertionID(0)
    private let source = CGEventSource(stateID: .hidSystemState)

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.info("keep-alive on: this Mac counts as in use while hosting")
        tick()
    }

    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        Log.info("keep-alive off")
    }

    /// Seconds since the last keyboard or mouse event, real or synthetic.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func tick() {
        // A viewer typing or clicking resets the idle time already; only nudge when it's quiet.
        // A locked Mac stays locked: input then only reaches the lock screen.
        guard Self.idleSeconds >= Self.idleThreshold, !ScreenLock.isLocked else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        // Also wakes the display if something turned it off anyway.
        IOPMAssertionDeclareUserActivity("Teleport keep-alive" as CFString, kIOPMUserActiveLocal, &assertion)
    }
}
