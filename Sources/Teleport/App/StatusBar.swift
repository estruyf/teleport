import AppKit
import Combine
import TeleportCore

/// The menu bar item: open the window, see the state, pair or connect, quit.
@MainActor
final class StatusBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let app: AppModel
    private let openWindow: () -> Void
    private var cancellable: AnyCancellable?
    private var menuOpen = false
    /// What the open menu shows of the viewer's apps, so it is only rebuilt when that changes.
    private var shownApps: [AppInfo] = []
    private var shownIcons = 0

    init(app: AppModel, openWindow: @escaping () -> Void) {
        self.app = app
        self.openWindow = openWindow
        super.init()
        item.button?.image = Self.portalIcon()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        cancellable = app.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.appChanged() }
        }
        updateBadge()
    }

    /// A small portal: a ring with a chevron rising out of it. Template, so it follows the bar's colour.
    static func portalIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: rect.midX, y: 6.5), radius: 6.5, startAngle: 200, endAngle: 340)
            ring.lineWidth = 1.8
            ring.lineCapStyle = .round
            ring.stroke()
            let inner = NSBezierPath()
            inner.appendArc(withCenter: NSPoint(x: rect.midX, y: 6.5), radius: 3.5, startAngle: 190, endAngle: 350)
            inner.lineWidth = 1.4
            inner.lineCapStyle = .round
            inner.stroke()
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: rect.midX - 4, y: 10.5))
            chevron.line(to: NSPoint(x: rect.midX, y: 15))
            chevron.line(to: NSPoint(x: rect.midX + 4, y: 10.5))
            chevron.lineWidth = 1.8
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func appChanged() {
        updateBadge()
        // The app list refreshes after the menu opens; show the fresh one without reopening.
        if menuOpen, let viewer = app.viewer, let menu = item.menu,
           viewer.apps != shownApps || viewer.icons.count != shownIcons {
            menuNeedsUpdate(menu)
        }
    }

    /// The icon says how the host is doing: orange while it is locked, red while the connection is lost.
    private func updateBadge() {
        let hosting = app.host?.state == .hosting
        let viewer = app.viewer
        let connected = viewer?.connected ?? false
        let locked = connected && viewer?.hostLocked == true
        let lost = viewer?.reconnecting == true
        item.button?.appearsDisabled = !(hosting || connected || lost) && app.config.mode != nil
        item.button?.contentTintColor = locked ? .systemOrange : lost ? .systemRed : nil
        let name = viewer?.current?.name ?? "the host"
        item.button?.toolTip = hosting ? "Teleport: hosting"
            : lost ? "Teleport: connection to \(name) lost, reconnecting"
            : locked ? "Teleport: \(name) is locked"
            : connected ? "Teleport: connected to \(name)" : "Teleport"
    }

    func menuWillOpen(_: NSMenu) {
        menuOpen = true
        if let viewer = app.viewer, viewer.connected { Task { await viewer.refresh() } }
    }

    func menuDidClose(_: NSMenu) { menuOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        shownApps = []
        menu.addItem(withTitle: "Open Teleport", action: #selector(open), keyEquivalent: "o").target = self

        if let host = app.host {
            menu.addItem(.separator())
            let status: String = switch host.state {
            case .hosting: "Hosting as \(host.config.deviceName)"
            case .starting: "Starting…"
            case .stopped: "Stopped"
            case .failed: "Failed to start"
            }
            menu.addItem(disabled(status))
            if host.state == .hosting {
                menu.addItem(disabled(host.viewers.isEmpty ? "No Mac connected" : "\(host.viewers.count) Mac(s) connected, \(host.openPortals.count) window(s) open"))
                for address in host.addresses { menu.addItem(disabled("  \(address):\(host.config.port)")) }
                menu.addItem(.separator())
                if let pairing = host.pairingCode {
                    menu.addItem(disabled("Pairing code: \(pairing.code.prefix(3)) \(pairing.code.suffix(3))"))
                    menu.addItem(withTitle: "Cancel pairing", action: #selector(cancelPairing), keyEquivalent: "").target = self
                } else {
                    menu.addItem(withTitle: "Show pairing code", action: #selector(startPairing), keyEquivalent: "").target = self
                }
                let keepAlive = NSMenuItem(title: "Keep This Mac from Locking", action: #selector(toggleKeepAlive), keyEquivalent: "")
                keepAlive.target = self
                keepAlive.state = host.config.keepAliveEnabled ? .on : .off
                menu.addItem(keepAlive)
                menu.addItem(withTitle: "Stop hosting", action: #selector(stopHost), keyEquivalent: "").target = self
            } else {
                menu.addItem(withTitle: "Start hosting", action: #selector(startHost), keyEquivalent: "").target = self
            }
        }

        if let viewer = app.viewer {
            menu.addItem(.separator())
            switch viewer.state {
            case let .connected(name):
                menu.addItem(disabled("Connected to \(name)"))
                for line in healthLines(viewer, hostName: name) { menu.addItem(line) }
                menu.addItem(withTitle: "Disconnect", action: #selector(disconnect), keyEquivalent: "").target = self
                addApps(of: viewer, hostName: name, to: menu)
            case let .connecting(name):
                menu.addItem(disabled(viewer.reconnecting ? "Connection to \(name) lost; reconnecting…" : "Connecting to \(name)…"))
                menu.addItem(withTitle: "Cancel", action: #selector(disconnect), keyEquivalent: "").target = self
            default:
                if viewer.hosts.isEmpty {
                    menu.addItem(disabled("No paired Mac"))
                }
                for host in viewer.hosts {
                    let entry = NSMenuItem(title: "Open portal for \(host.name)", action: #selector(connect(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = host.publicKey
                    menu.addItem(entry)
                    let reachability = viewer.reachability[host.publicKey]
                    menu.addItem(disabled("    " + Self.describe(reachability)))
                    if case .offline = reachability, host.macAddress != nil {
                        let wake = NSMenuItem(title: "    Wake \(host.name)", action: #selector(wakeHost(_:)), keyEquivalent: "")
                        wake.target = self
                        wake.representedObject = host.publicKey
                        menu.addItem(wake)
                    }
                }
            }
        }

        menu.addItem(.separator())
        if app.updater.isAvailable {
            if let pending = app.updater.pendingVersion {
                menu.addItem(disabled("Update \(pending) installs when no Mac is connected"))
            }
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self
            check.isEnabled = app.updater.canCheckForUpdates
            menu.addItem(check)
        }
        menu.addItem(withTitle: "Quit Teleport", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// The connected host's shared apps; a running app's submenu lists its windows, a check marking the ones open here.
    private func addApps(of viewer: ViewerController, hostName: String, to menu: NSMenu) {
        shownApps = viewer.apps
        shownIcons = viewer.icons.count
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Apps on \(hostName)"))
        if viewer.apps.isEmpty {
            menu.addItem(disabled("No shared apps"))
            return
        }
        let open = viewer.openWindowIDs
        for remoteApp in viewer.apps {
            let entry = NSMenuItem(title: remoteApp.name, action: nil, keyEquivalent: "")
            entry.image = viewer.icons[remoteApp.bundleID].map(Self.menuIcon)
            if let unread = viewer.badges[remoteApp.bundleID] { entry.badge = NSMenuItemBadge(string: unread) }
            if remoteApp.running {
                let actions = NSMenu()
                actions.addItem(action("New Window", #selector(newWindow(_:)), remoteApp))
                actions.addItem(.separator())
                if !remoteApp.windows.isEmpty {
                    actions.addItem(.sectionHeader(title: "Instances"))
                    for window in remoteApp.windows {
                        let row = action(window.title.isEmpty ? "Untitled" : window.title, #selector(openPortal(_:)), window)
                        row.state = open.contains(window.id) ? .on : .off
                        actions.addItem(row)
                    }
                    actions.addItem(.separator())
                }
                actions.addItem(action("Quit \(remoteApp.name)", #selector(quitApp(_:)), remoteApp))
                // Holding Option turns Quit into Force Quit, as in the Dock.
                let force = action("Force Quit \(remoteApp.name)…", #selector(forceQuitApp(_:)), remoteApp)
                force.isAlternate = true
                force.keyEquivalentModifierMask = .option
                actions.addItem(force)
                entry.submenu = actions
            } else {
                entry.action = #selector(launchApp(_:))
                entry.target = self
                entry.representedObject = remoteApp
                entry.toolTip = "Launch \(remoteApp.name) on \(hostName)"
            }
            menu.addItem(entry)
        }
    }

    /// What's worth knowing about the connected host, as menu lines; nothing when all is well.
    private func healthLines(_ viewer: ViewerController, hostName: String) -> [NSMenuItem] {
        var lines: [NSMenuItem] = []
        if viewer.hostLocked {
            lines.append(warning("\(hostName) is locked: typing and new windows won't work"))
        }
        if viewer.microphoneLive { lines.append(disabled("Microphone on: an app there is listening")) }
        if let version = viewer.hostInfo?.version, version != TeleportVersion.string, version != "dev", TeleportVersion.string != "dev" {
            lines.append(disabled("\(hostName) runs Teleport \(version), this Mac \(TeleportVersion.string)"))
        }
        return lines
    }

    private static func describe(_ reachability: ViewerController.Reachability?) -> String {
        switch reachability {
        case .online: return "Online"
        case let .offline(lastSeen?): return "Offline · seen \(RelativeDateTimeFormatter().localizedString(for: lastSeen, relativeTo: Date()))"
        case .offline(nil): return "Offline"
        case nil: return "Checking…"
        }
    }

    private func warning(_ title: String) -> NSMenuItem {
        let entry = disabled(title)
        entry.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        return entry
    }

    private static func menuIcon(_ image: NSImage) -> NSImage {
        let icon = image.copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func action(_ title: String, _ selector: Selector, _ object: Any) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.representedObject = object
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    @objc private func open() { openWindow() }
    @objc private func checkForUpdates() { app.updater.checkForUpdates() }
    @objc private func startPairing() { app.host?.startPairing(); openWindow() }
    @objc private func cancelPairing() { app.host?.cancelPairing() }
    @objc private func startHost() { Task { await app.host?.start() } }
    @objc private func stopHost() { Task { await app.host?.stop() } }
    @objc private func toggleKeepAlive() {
        guard let host = app.host else { return }
        host.setKeepAlive(!host.config.keepAliveEnabled)
    }
    @objc private func disconnect() { Task { await app.viewer?.disconnect() } }
    @objc private func launchApp(_ sender: NSMenuItem) {
        guard let remoteApp = sender.representedObject as? AppInfo else { return }
        Task { await app.viewer?.launch(remoteApp, newWindow: false) }
    }

    @objc private func newWindow(_ sender: NSMenuItem) {
        guard let remoteApp = sender.representedObject as? AppInfo else { return }
        Task { await app.viewer?.launch(remoteApp, newWindow: true) }
    }

    @objc private func openPortal(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowInfo else { return }
        NSApp.activate(ignoringOtherApps: true)
        Task { await app.viewer?.open(window) }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let remoteApp = sender.representedObject as? AppInfo else { return }
        Task { await app.viewer?.quit(remoteApp, force: false) }
    }

    @objc private func forceQuitApp(_ sender: NSMenuItem) {
        guard let remoteApp = sender.representedObject as? AppInfo else { return }
        let alert = NSAlert()
        alert.messageText = "Force quit \(remoteApp.name) on the host?"
        alert.informativeText = "Unsaved changes in \(remoteApp.name) are lost."
        alert.addButton(withTitle: "Force Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await app.viewer?.quit(remoteApp, force: true) }
    }

    @objc private func wakeHost(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let host = app.viewer?.hosts.first(where: { $0.publicKey == key }) else { return }
        app.viewer?.wake(host)
    }

    @objc private func connect(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let host = app.viewer?.hosts.first(where: { $0.publicKey == key }) else { return }
        Task { await app.viewer?.connect(host) }
    }
}
