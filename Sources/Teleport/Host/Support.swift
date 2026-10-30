import AppKit
import Darwin
import TeleportCore

/// Addresses a viewer can reach this Mac on: LAN IPv4s and the Tailscale address (100.64/10).
enum NetworkAddresses {
    static func current() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if ip.hasPrefix("169.254.") { continue }
                result.append(ip)
            }
        }
        // Tailscale first: it works from anywhere.
        return result.sorted { ($0.hasPrefix("100.") ? 0 : 1, $0) < ($1.hasPrefix("100.") ? 0 : 1, $1) }
    }
}

/// Whether this Mac's session is locked. Synthetic key events then go to the lock screen,
/// not the apps, while window capture carries on, so portals open but nothing types.
enum ScreenLock {
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool ?? true
        return locked || !onConsole
    }
}

struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID }
}

/// Apps the host can offer in its allow-list.
enum InstalledApps {
    static func scan() -> [InstalledApp] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                apps.append(InstalledApp(bundleID: id, name: name, url: url))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func icon(for app: InstalledApp) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.url.path)
    }
}

/// Drags a file into the window under `point` on this Mac.
///
/// A tiny transparent window sits under the cursor and starts a real `NSDraggingSession`
/// when the synthetic mouse-down lands on it; synthetic moves then carry it to the target.
@MainActor
enum FileDrop {
    private static var sourceWindow: NSWindow?

    static func perform(file: URL, at point: CGPoint) {
        // Start the drag a little away from the target so the drop is a real move.
        let start = CGPoint(x: point.x - 60, y: point.y - 60)
        let view = DragSourceView(file: file)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 24, height: 24), styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.contentView = view
        // AppKit's origin is bottom-left; CG's is top-left on the main display.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        window.setFrameOrigin(NSPoint(x: start.x - 12, y: screenHeight - start.y - 12))
        window.orderFrontRegardless()
        sourceWindow = window

        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ location: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { post(.leftMouseDown, start) }
        // Several moves so the receiving app sees a drag enter and update.
        for (i, t) in [0.25, 0.35, 0.45, 0.55].enumerated() {
            let fraction = CGFloat(i + 1) / 4
            let location = CGPoint(x: start.x + (point.x - start.x) * fraction, y: start.y + (point.y - start.y) * fraction)
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { post(.leftMouseDragged, location) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { post(.leftMouseUp, point) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            sourceWindow?.orderOut(nil)
            sourceWindow = nil
        }
    }

    final class DragSourceView: NSView, NSDraggingSource {
        let file: URL
        init(file: URL) {
            self.file = file
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: file as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: file.path)
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation { .copy }
    }
}
