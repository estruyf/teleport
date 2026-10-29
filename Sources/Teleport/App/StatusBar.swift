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

    init(app: AppModel, openWindow: @escaping () -> Void) {
        self.app = app
        self.openWindow = openWindow
        super.init()
        item.button?.image = Self.portalIcon()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        cancellable = app.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateBadge() }
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

    private func updateBadge() {
        let hosting = app.host?.state == .hosting
        let connected = app.viewer?.connected ?? false
        item.button?.appearsDisabled = !(hosting || connected) && app.config.mode != nil
        item.button?.toolTip = hosting ? "Teleport: hosting" : connected ? "Teleport: connected" : "Teleport"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
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
                menu.addItem(withTitle: "Disconnect", action: #selector(disconnect), keyEquivalent: "").target = self
            case let .connecting(name):
                menu.addItem(disabled("Connecting to \(name)…"))
                menu.addItem(withTitle: "Cancel", action: #selector(disconnect), keyEquivalent: "").target = self
            default:
                if viewer.hosts.isEmpty {
                    menu.addItem(disabled("No paired Mac"))
                }
                for host in viewer.hosts {
                    let entry = NSMenuItem(title: "Teleport to \(host.name)", action: #selector(connect(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = host.publicKey
                    menu.addItem(entry)
                }
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Teleport", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    @objc private func open() { openWindow() }
    @objc private func startPairing() { app.host?.startPairing(); openWindow() }
    @objc private func cancelPairing() { app.host?.cancelPairing() }
    @objc private func startHost() { Task { await app.host?.start() } }
    @objc private func stopHost() { Task { await app.host?.stop() } }
    @objc private func disconnect() { Task { await app.viewer?.disconnect() } }
    @objc private func connect(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let host = app.viewer?.hosts.first(where: { $0.publicKey == key }) else { return }
        Task { await app.viewer?.connect(host) }
    }
}
