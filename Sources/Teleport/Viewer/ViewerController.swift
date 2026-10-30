import AppKit
import LiveKit
import TeleportCore

/// Viewer side: paired hosts, the connection to one of them, its apps and portal windows.
@MainActor
final class ViewerController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, connecting(String), connected(String), failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var hosts: [PairedHost] = []
    @Published private(set) var current: PairedHost?
    @Published private(set) var apps: [AppInfo] = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    /// The host's screen is locked: portals still show, but typing and new windows don't work.
    @Published private(set) var hostLocked = false
    /// Shown while the host decides on a pairing.
    @Published private(set) var pairingFingerprint: String?

    let identity: DeviceIdentity
    let deviceName: String
    private let room = Room()
    private var hostIdentity = Participant.Identity(from: HostController.identity)
    private var portals: [UInt32: PortalWindowController] = [:]
    /// Tracks that arrived before their open() reply did.
    private var pendingTracks: [String: RemoteVideoTrack] = [:]
    private let dockTiles = DockTileManager()
    private let hostStore = JSONListStore<PairedHost>(filename: "hosts.json")
    private let clipboard = ClipboardSync()
    private var userDisconnecting = false
    private var reconnectTask: Task<Void, Never>?
    /// Windows that were open when the connection dropped; reopened after a reconnect.
    private var reopenAfterReconnect: [WindowInfo] = []
    var clipboardSyncEnabled = true

    var connected: Bool { if case .connected = state { true } else { false } }

    init(identity: DeviceIdentity, deviceName: String) {
        self.identity = identity
        self.deviceName = deviceName
        super.init()
        hosts = hostStore.load()
        room.add(delegate: self)
        clipboard.onChange = { [weak self] text in self?.sendClipboard(text) }
        dockTiles.onActivate = { [weak self] bundleID in
            self?.focusApp(bundleID)
        }
    }

    // MARK: - Pairing

    func pair(address: String, port: Int = 7880, code: String) async {
        busy = true
        notice = nil
        pairingFingerprint = nil
        defer { busy = false; pairingFingerprint = nil }
        do {
            let host = try await HostClient.pair(address: address, port: port, code: code, identity: identity, name: deviceName) { [weak self] fingerprint in
                self?.pairingFingerprint = fingerprint
            }
            hosts.removeAll { $0.publicKey == host.publicKey }
            hosts.append(host)
            try? hostStore.save(hosts)
            notice = "Paired with \(host.name)."
            Sounds.paired()
            await connect(host)
        } catch {
            notice = Self.friendly(error, host: nil)
        }
    }

    func forget(_ host: PairedHost) {
        if current?.publicKey == host.publicKey { Task { await disconnect() } }
        hosts.removeAll { $0.publicKey == host.publicKey }
        try? hostStore.save(hosts)
    }

    // MARK: - Connection

    func connect(_ host: PairedHost) async {
        if connected { await disconnect() }
        reconnectTask?.cancel()
        userDisconnecting = false
        state = .connecting(host.name)
        notice = nil
        do {
            try await join(host)
            Sounds.connected()
            await refresh()
        } catch {
            state = .failed(Self.friendly(error, host: host))
        }
    }

    private func join(_ host: PairedHost) async throws {
        let result = try await HostClient.token(for: host, identity: identity)
        hostIdentity = Participant.Identity(from: result.hostIdentity)
        try await room.connect(url: host.signalURL, token: result.token, connectOptions: ConnectOptions(autoSubscribe: true))
        current = host
        state = .connected(host.name)
        if clipboardSyncEnabled { clipboard.start() }
    }

    func disconnect() async {
        userDisconnecting = true
        reconnectTask?.cancel()
        reconnectTask = nil
        clipboard.stop()
        for portal in portals.values { portal.close() }
        portals.removeAll()
        dockTiles.removeAll()
        await room.disconnect()
        current = nil
        apps = []
        hostLocked = false
        state = .idle
    }

    /// The host went away or the network dropped: keep trying for a couple of minutes.
    private func scheduleReconnect(after error: LiveKitError?) {
        guard let host = current, !userDisconnecting else { return }
        reopenAfterReconnect = portals.values.map(\.info)
        for portal in portals.values { portal.hostClosed() }
        portals.removeAll()
        dockTiles.removeAll()
        clipboard.stop()
        apps = []
        hostLocked = false
        state = .connecting(host.name)
        notice = "Connection to \(host.name) lost. Reconnecting…"
        Log.warn("disconnected from \(host.name): \(String(describing: error)); reconnecting")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let delays: [UInt64] = [2, 4, 8, 15, 30, 30, 30]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let self, !Task.isCancelled, !self.userDisconnecting else { return }
                do {
                    try await self.join(host)
                    self.notice = nil
                    await self.refresh()
                    let toReopen = self.reopenAfterReconnect
                    self.reopenAfterReconnect = []
                    for window in toReopen where self.apps.contains(where: { $0.windows.contains(where: { $0.id == window.id }) }) {
                        await self.open(window)
                    }
                    return
                } catch {
                    Log.warn("reconnect to \(host.name) failed: \(error)")
                }
            }
            guard let self else { return }
            self.current = nil
            self.state = .failed("Could not reconnect to \(host.name). Is Teleport still running there?")
        }
    }

    /// Errors in plain words.
    static func friendly(_ error: Error, host: PairedHost?) -> String {
        let name = host?.name ?? "the host"
        if let pairing = error as? PairingError {
            switch pairing {
            case .notTrusted: return "\(name) no longer knows this Mac. Pair again."
            case let .unreachable(detail):
                if detail.lowercased().contains("timed out") || detail.lowercased().contains("could not connect") || detail.lowercased().contains("connection refused") {
                    return "Can't reach \(name). Is Teleport running and hosting there?"
                }
                return "Can't reach \(name): \(detail)"
            default: return "\(pairing)"
            }
        }
        if let livekit = error as? LiveKitError {
            switch livekit.type {
            case .network, .timedOut: return "Can't reach \(name)'s streaming server. Is it hosting?"
            case .serverPingTimedOut: return "Lost contact with \(name)."
            default: break
            }
            return "Streaming failed with \(name): \(livekit.message ?? "\(livekit.type)")"
        }
        if (error as? URLError) != nil { return "Can't reach \(name). Check the address and that Teleport runs there." }
        return "\(error)"
    }

    // MARK: - Clipboard

    private func sendClipboard(_ text: String) {
        guard connected, clipboardSyncEnabled, let data = try? JSONEncoder().encode(ClipboardMessage(text: text)) else { return }
        Task { try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: Topic.clipboard, reliable: true)) }
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
            notice = "Listing apps failed: \(error)"
        }
    }

    // MARK: - Portals

    func open(_ window: WindowInfo) async {
        if let existing = portals[window.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let reply = try await rpc(RPCMethod.open, try OpenRequest(windowID: window.id).jsonString(), timeout: 20)
            let response = try RPCReply.decode(OpenResponse.self, from: reply)
            let portal = PortalWindowController(info: response.window, hostName: current?.name ?? "", viewer: self)
            portals[window.id] = portal
            if let track = pendingTracks.removeValue(forKey: response.trackName) {
                portal.attach(track: track)
            }
            portal.showWindow(nil)
            Sounds.portalOpened()
            if let icon = await loadIcon(for: window.bundleID) {
                dockTiles.ensureTile(bundleID: window.bundleID, appName: window.app, icon: icon)
            }
        } catch {
            notice = "Could not open \(window.app): \(Self.friendly(error, host: current))"
        }
    }

    /// Launches the app (or asks a running one for a new window) and opens what appears.
    func launch(_ app: AppInfo, newWindow: Bool) async {
        busy = true
        defer { busy = false }
        notice = nil
        do {
            let request = LaunchRequest(bundleID: app.bundleID, newWindow: newWindow)
            let reply = try await rpc(RPCMethod.launch, try request.jsonString(), timeout: 30)
            let response = try RPCReply.decode(LaunchResponse.self, from: reply)
            if response.windows.isEmpty {
                notice = "\(app.name) did not open a window."
            } else {
                for window in response.windows { await open(window) }
            }
            await refresh()
        } catch {
            notice = "Could not launch \(app.name): \(Self.friendly(error, host: current))"
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

    /// Sends a dropped file to the host, which drags it into the window at (x, y).
    func sendFile(_ url: URL, windowID: UInt32, x: Double, y: Double) {
        Task {
            do {
                let options = StreamByteOptions(
                    topic: Topic.files,
                    attributes: [FileDropKeys.windowID: String(windowID), FileDropKeys.x: String(x), FileDropKeys.y: String(y)],
                    name: url.lastPathComponent
                )
                _ = try await room.localParticipant.sendFile(url, options: options)
            } catch {
                notice = "Sending \(url.lastPathComponent) failed: \(error)"
            }
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

    nonisolated func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType _: EncryptionType) {
        switch topic {
        case Topic.clipboard:
            Task { @MainActor in
                guard self.clipboardSyncEnabled, let message = try? JSONDecoder().decode(ClipboardMessage.self, from: data) else { return }
                self.clipboard.apply(message.text)
            }
        case Topic.hostStatus:
            Task { @MainActor in
                guard let status = try? JSONDecoder().decode(HostStatus.self, from: data) else { return }
                self.hostLocked = status.locked
            }
        default: break
        }
    }

    nonisolated func room(_: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            if self.userDisconnecting { return }
            self.scheduleReconnect(after: error)
        }
    }
}
