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
        let image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Teleport")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        cancellable = app.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateBadge() }
        }
    }

    private func updateBadge() {
        let hosting = app.host?.state == .hosting
        let connected = app.viewer?.connected ?? false
        item.button?.appearsDisabled = !(hosting || connected) && app.config.mode != nil
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
                menu.addItem(disabled(host.viewers.isEmpty ? "No viewer connected" : "\(host.viewers.count) viewer(s), \(host.openPortals.count) window(s)"))
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
            default:
                if viewer.hosts.isEmpty {
                    menu.addItem(disabled("No paired Mac"))
                }
                for host in viewer.hosts {
                    let entry = NSMenuItem(title: "Connect to \(host.name)", action: #selector(connect(_:)), keyEquivalent: "")
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
