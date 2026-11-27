import AppKit
import ApplicationServices
import TeleportCore

/// Reads the notification banners macOS shows on this Mac, so a viewer can see the ones from shared apps.
///
/// macOS has no API for another app's notifications. Notification Center draws each banner as an
/// accessibility element (subrole `AXNotificationCenterBanner`) with a UUID identifier that stays the
/// same while it shows, child texts tagged `title`, `subtitle` and `body`, and a description that
/// starts with the app's name. Reading it needs Accessibility, which hosting needs anyway.
///
/// A new banner replaces the one on screen right away, so this scans a few times a second; one that
/// comes and goes between two scans is missed. Banners only show while the Mac is unlocked and no
/// Focus holds them back, and only for apps whose notification style is Banners or Alerts.
final class NotificationWatcher: @unchecked Sendable {
    struct Banner: Sendable {
        let id: String
        let app: String
        let title: String
        let subtitle: String
        let body: String
    }

    static let interval: TimeInterval = 0.4
    private static let bundleID = "com.apple.notificationcenterui"

    /// Everything below runs on this queue: Accessibility calls into another process can stall.
    private let queue = DispatchQueue(label: "teleport.notifications", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var app: (pid: pid_t, element: AXUIElement)?
    /// Banners already reported, by identifier, with when they were last on screen.
    private var seen: [String: Date] = [:]
    /// The first scan only fills `seen`: what was on screen before watching started isn't news.
    private var primed = false
    private let onBanner: @MainActor (Banner) -> Void

    init(onBanner: @escaping @MainActor (Banner) -> Void) {
        self.onBanner = onBanner
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            primed = false
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.scan() }
            timer.resume()
            self.timer = timer
            Log.info("notifications: watching for banners from shared apps")
        }
    }

    func stop() {
        queue.async { [self] in
            guard let timer else { return }
            timer.cancel()
            self.timer = nil
            seen = [:]
            Log.info("notifications: stopped watching")
        }
    }

    /// Clicks the banner on this Mac, which opens its app where the notification points, as long as
    /// it is still on screen and belongs to an app with one of `appNames`.
    func click(id: String, appNames: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let match = banners().first { $0.banner.id == id && BannerText.matches($0.banner.app, any: appNames) }
                let clicked = match.map { AXUIElementPerformAction($0.element, kAXPressAction as CFString) == .success } ?? false
                continuation.resume(returning: clicked)
            }
        }
    }

    private func scan() {
        let now = Date()
        var fresh: [Banner] = []
        for (banner, _) in banners() {
            if seen[banner.id] == nil, primed { fresh.append(banner) }
            seen[banner.id] = now
        }
        primed = true
        // Forget banners that have been gone for a while; an identifier never comes back.
        if seen.count > 50 { seen = seen.filter { now.timeIntervalSince($0.value) < 60 } }
        guard !fresh.isEmpty else { return }
        let onBanner = onBanner
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for banner in fresh { onBanner(banner) } }
        }
    }

    // MARK: - Accessibility

    private func banners() -> [(banner: Banner, element: AXUIElement)] {
        guard let app = notificationCenter() else { return [] }
        var found: [(Banner, AXUIElement)] = []
        for window in Self.elements(app, kAXWindowsAttribute) {
            collect(window, depth: 0, into: &found)
        }
        return found
    }

    /// The Notification Center process, which macOS restarts now and then.
    private func notificationCenter() -> AXUIElement? {
        if let app, NSRunningApplication(processIdentifier: app.pid)?.isTerminated == false { return app.element }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            app = nil
            return nil
        }
        let element = AXUIElementCreateApplication(running.processIdentifier)
        // A hung Notification Center must not hold up the scans for the default six seconds.
        AXUIElementSetMessagingTimeout(element, 0.5)
        app = (running.processIdentifier, element)
        return element
    }

    private func collect(_ element: AXUIElement, depth: Int, into found: inout [(Banner, AXUIElement)]) {
        // The desktop widgets live in this process too; their trees are of no interest.
        let identifier = Self.string(element, kAXIdentifierAttribute) ?? ""
        guard depth < 8, !identifier.hasPrefix("widget") else { return }
        if Self.string(element, kAXSubroleAttribute)?.hasPrefix("AXNotificationCenter") == true, !identifier.isEmpty,
           let banner = Self.banner(element, id: identifier)
        {
            found.append((banner, element))
            return
        }
        for child in Self.elements(element, kAXChildrenAttribute) {
            collect(child, depth: depth + 1, into: &found)
        }
    }

    private static func banner(_ element: AXUIElement, id: String) -> Banner? {
        var texts: [String: String] = [:]
        for child in elements(element, kAXChildrenAttribute) {
            guard let key = string(child, kAXIdentifierAttribute), ["title", "subtitle", "body"].contains(key) else { continue }
            texts[key] = string(child, kAXValueAttribute) ?? ""
        }
        let title = texts["title"] ?? "", subtitle = texts["subtitle"] ?? "", body = texts["body"] ?? ""
        // A stack or a group without texts of its own: its banners are further down.
        guard !(title.isEmpty && body.isEmpty),
              let app = BannerText.appName(description: string(element, kAXDescriptionAttribute) ?? "", title: title, subtitle: subtitle, body: body)
        else { return nil }
        return Banner(id: id, app: app, title: title, subtitle: subtitle, body: body)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
