import AppKit
import ApplicationServices
import TeleportCore

/// Reads the Dock badges (unread counts) of the shared apps, so the viewer's Dock can show them.
///
/// The Dock describes each app's icon as an accessibility element (`AXApplicationDockItem`) with
/// the app's location in `AXURL` and the badge text in `AXStatusLabel`. Reading it needs
/// Accessibility, which hosting needs anyway. An app shows up there while it runs.
final class DockBadgeWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "teleport.badges", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var allowedApps: [String] = []
    private var last: [String: String]?
    /// Bundle IDs by app location; looking one up opens the bundle.
    private var bundleIDs: [URL: String] = [:]
    private let onChange: @MainActor ([String: String]) -> Void

    init(onChange: @escaping @MainActor ([String: String]) -> Void) {
        self.onChange = onChange
    }

    func start(allowedApps: [String]) {
        queue.async { [self] in
            self.allowedApps = allowedApps
            guard timer == nil else { return }
            last = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.scan() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            last = nil
        }
    }

    /// The current badges, for a viewer that just joined.
    func current(_ reply: @escaping @MainActor ([String: String]) -> Void) {
        queue.async { [self] in
            let badges = last ?? [:]
            DispatchQueue.main.async { MainActor.assumeIsolated { reply(badges) } }
        }
    }

    private func scan() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var badges: [String: String] = [:]
        for list in Self.children(app) {
            for item in Self.children(list) where Self.string(item, kAXSubroleAttribute) == "AXApplicationDockItem" {
                guard let label = Self.string(item, "AXStatusLabel"), !label.isEmpty,
                      let url = Self.url(item), let bundleID = bundleID(at: url),
                      allowedApps.contains(bundleID)
                else { continue }
                badges[bundleID] = label
            }
        }
        guard badges != last else { return }
        last = badges
        let onChange = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange(badges) } }
    }

    private func bundleID(at url: URL) -> String? {
        if let known = bundleIDs[url] { return known }
        let id = Bundle(url: url)?.bundleIdentifier
        if let id { bundleIDs[url] = id }
        return id
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func url(_ element: AXUIElement) -> URL? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        return value as? URL
    }
}
