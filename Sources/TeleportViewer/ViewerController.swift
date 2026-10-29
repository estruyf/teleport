import AppKit
import LiveKit
import TeleportCore

/// Viewer side: connects to a host, lists its apps and opens portal windows.
@MainActor
final class ViewerController: NSObject, ObservableObject {
    @Published private(set) var status = "Not connected"
    @Published private(set) var apps: [AppInfo] = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var connected = false
    @Published private(set) var hostName = ""

    private let room = Room()
    private var config: TeleportConfig!
    private var hostIdentity: Participant.Identity { .init(from: "teleport-host") }
    private var portals: [UInt32: PortalWindowController] = [:]
    /// Tracks that arrived before their open() reply did.
    private var pendingTracks: [String: RemoteVideoTrack] = [:]
    private let dockTiles = DockTileManager()

    override init() {
        super.init()
        room.add(delegate: self)
        dockTiles.onActivate = { [weak self] bundleID in
            self?.focusApp(bundleID)
        }
    }

    func connect(to host: String) async {
        do {
            config = try TeleportConfig.load()
        } catch {
            status = "Copy the host's ~/.teleport/config.json to this Mac first (\(error.localizedDescription))"
            return
        }
        status = "Connecting to \(host)…"
        do {
            let url = "ws://\(host):\(config.port)"
            try await room.connect(
                url: url,
                token: AccessToken.make(config: config, identity: "viewer-\(Host.current().localizedName ?? "mac")"),
                connectOptions: ConnectOptions(autoSubscribe: true)
            )
            connected = true
            hostName = host
            status = "Connected to \(host)"
            await refresh()
        } catch {
            status = "Connection failed: \(error)"
        }
    }

    func disconnect() async {
        for portal in portals.values { portal.close() }
        portals.removeAll()
        dockTiles.removeAll()
        await room.disconnect()
        connected = false
        apps = []
        status = "Not connected"
    }

    func refresh() async {
        guard connected else { return }
        do {
            let reply = try await rpc(RPCMethod.apps, "{}")
            apps = try RPCReply.decode([AppInfo].self, from: reply)
            for app in apps where icons[app.bundleID] == nil {
                Task { await loadIcon(for: app.bundleID) }
            }
        } catch {
            status = "Listing apps failed: \(error)"
        }
    }

    func open(_ window: WindowInfo) async {
        if let existing = portals[window.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let reply = try await rpc(RPCMethod.open, try OpenRequest(windowID: window.id).jsonString(), timeout: 20)
            let response = try RPCReply.decode(OpenResponse.self, from: reply)
            let portal = PortalWindowController(info: response.window, hostName: hostName, viewer: self)
            portals[window.id] = portal
            if let track = pendingTracks.removeValue(forKey: response.trackName) {
                portal.attach(track: track)
            }
            portal.showWindow(nil)
            if let icon = await loadIcon(for: window.bundleID) {
                dockTiles.ensureTile(bundleID: window.bundleID, appName: window.app, icon: icon)
            }
        } catch {
            status = "Open failed: \(error)"
        }
    }

    /// Launches the app (or asks a running one for a new window) and opens what appears.
    func launch(_ app: AppInfo, newWindow: Bool) async {
        status = newWindow ? "Opening a new \(app.name) window…" : "Launching \(app.name)…"
        do {
            let request = LaunchRequest(bundleID: app.bundleID, newWindow: newWindow)
            let reply = try await rpc(RPCMethod.launch, try request.jsonString(), timeout: 30)
            let response = try RPCReply.decode(LaunchResponse.self, from: reply)
            if response.windows.isEmpty {
                status = "\(app.name) did not open a window"
            } else {
                status = "Connected to \(hostName)"
                for window in response.windows { await open(window) }
            }
            await refresh()
        } catch {
            status = "Launch failed: \(error)"
        }
    }

    /// Dock tile clicked: bring that app's portals forward, or open one if none is open.
    func focusApp(_ bundleID: String) {
        NSApp.activate(ignoringOtherApps: true)
        let open = portals.values.filter { $0.info.bundleID == bundleID }
        if open.isEmpty {
            guard let app = apps.first(where: { $0.bundleID == bundleID }) else { return }
            Task {
                if let first = app.windows.first { await self.open(first) } else { await launch(app, newWindow: false) }
            }
        } else {
            for portal in open { portal.window?.orderFront(nil) }
            open.first?.window?.makeKey()
        }
    }

    // MARK: - Called by portal windows

    func portalClosed(_ windowID: UInt32) {
        guard let portal = portals.removeValue(forKey: windowID) else { return }
        fireAndForget(RPCMethod.close, CloseRequest(windowID: windowID))
        let bundleID = portal.info.bundleID
        if !portals.values.contains(where: { $0.info.bundleID == bundleID }) {
            dockTiles.removeTile(bundleID: bundleID)
        }
    }

    func requestResize(_ windowID: UInt32, to size: CGSize) {
        fireAndForget(RPCMethod.resize, ResizeRequest(windowID: windowID, width: size.width, height: size.height))
    }

    func send(_ event: InputEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        Task {
            try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: Topic.input, reliable: true))
        }
    }

    // MARK: - Helpers

    private func rpc(_ method: String, _ payload: String, timeout: TimeInterval = 15) async throws -> String {
        try await room.localParticipant.performRpc(destinationIdentity: hostIdentity, method: method, payload: payload, responseTimeout: timeout)
    }

    private func fireAndForget<T: Encodable>(_ method: String, _ request: T) {
        guard let payload = try? request.jsonString() else { return }
        Task { _ = try? await rpc(method, payload) }
    }

    /// Prefers the icon of a local copy of the same app; falls back to asking the host.
    @discardableResult
    private func loadIcon(for bundleID: String) async -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        if let local = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: local.path)
            icons[bundleID] = icon
            return icon
        }
        guard let reply = try? await rpc(RPCMethod.icon, try IconRequest(bundleID: bundleID).jsonString()),
              let response = try? RPCReply.decode(IconResponse.self, from: reply),
              let data = Data(base64Encoded: response.png),
              let icon = NSImage(data: data)
        else { return nil }
        icons[bundleID] = icon
        return icon
    }

    private func trackArrived(_ track: RemoteVideoTrack, name: String) {
        guard let id = TrackName.windowID(from: name) else { return }
        if let portal = portals[id] {
            portal.attach(track: track)
        } else {
            pendingTracks[name] = track
        }
    }

    private func trackLeft(name: String) {
        pendingTracks.removeValue(forKey: name)
        guard let id = TrackName.windowID(from: name), let portal = portals[id] else { return }
        portal.hostClosed()
        portalClosed(id)
    }
}

extension ViewerController: RoomDelegate {
    nonisolated func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? RemoteVideoTrack else { return }
        let name = publication.name
        Task { @MainActor in self.trackArrived(track, name: name) }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        let name = publication.name
        Task { @MainActor in self.trackLeft(name: name) }
    }

    nonisolated func room(_: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            self.connected = false
            self.status = "Disconnected: \(error.map { "\($0)" } ?? "closed")"
            for portal in self.portals.values { portal.hostClosed() }
            self.portals.removeAll()
            self.dockTiles.removeAll()
        }
    }
}
