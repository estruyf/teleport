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
    private var portals: [UInt32: PortalWindowController] = [:] {
        didSet { if Set(portals.keys) != openWindowIDs { openWindowIDs = Set(portals.keys) } }
    }
    /// Tracks that arrived before their open() reply did.
    private var pendingTracks: [String: RemoteVideoTrack] = [:]
    /// Windows whose open() is on its way, so a double click doesn't make two portals.
    private var opening: Set<UInt32> = []
    /// Input goes out one event at a time. A Task per event could overtake another inside the
    /// SDK's send path, and a key-up before its key-down types the wrong thing on the host.
    private let inputQueue: AsyncStream<Data>.Continuation
    private var inputTask: Task<Void, Never>?
    private let dockTiles = DockTileManager()
    private let notifications = NotificationPresenter()
    private let hostStore = JSONListStore<PairedHost>(filename: "hosts.json")
    private let clipboard = ClipboardSync()
    private var userDisconnecting = false
    private var reconnectTask: Task<Void, Never>?
    /// Windows that were open when the connection dropped; reopened after a reconnect.
    private var reopenAfterReconnect: [WindowInfo] = []
    var clipboardSyncEnabled = true
    /// Show the host's notifications from shared apps here.
    var notificationsEnabled = true
    /// Save files the shared apps download on the host to Downloads here.
    var downloadsEnabled = true
    /// Whether each paired host answers, by public key; checked every 30 s while not connected to it.
    @Published private(set) var reachability: [String: Reachability] = [:]
    /// What the connected host said about itself, for the menu bar.
    @Published private(set) var hostInfo: HostInfo?
    private var probeTask: Task<Void, Never>?

    enum Reachability: Equatable {
        case online
        case offline(lastSeen: Date?)
    }

    /// Unread counts of the shared apps, by bundle ID, as their Dock icons show them on the host.
    @Published private(set) var badges: [String: String] = [:]
    /// Play the shared apps' sound here.
    var audioEnabled = true {
        didSet { applyAudioVolume() }
    }
    /// Send this Mac's microphone while a shared app on the host listens to one.
    var microphoneEnabled = false {
        didSet { updateMicrophone() }
    }
    /// This Mac's microphone is going to the host right now.
    @Published private(set) var microphoneLive = false
    /// The host asks for the microphone: one of its shared apps listens to one.
    private var hostWantsMicrophone = false
    private var hostAudio: RemoteAudioTrack?
    private var microphonePublication: LocalTrackPublication?
    private var microphoneQueue: Task<Void, Never>?
    /// The `video` settings that apply to a viewer: stats and the measurement probe.
    var videoTuning = VideoTuning(VideoConfig())

    var connected: Bool { if case .connected = state { true } else { false } }
    /// The connection dropped and the viewer is trying to get it back.
    var reconnecting: Bool { reconnectTask != nil }

    /// Host windows that have a portal open here.
    /// The remote windows open in a portal here, published so the window list can mark them.
    @Published private(set) var openWindowIDs: Set<UInt32> = []

    init(identity: DeviceIdentity, deviceName: String) {
        self.identity = identity
        self.deviceName = deviceName
        let (inputStream, inputQueue) = AsyncStream<Data>.makeStream()
        self.inputQueue = inputQueue
        super.init()
        inputTask = Task { [room] in
            for await data in inputStream {
                try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: Topic.input, reliable: true))
            }
        }
        hosts = hostStore.load()
        room.add(delegate: self)
        clipboard.onChange = { [weak self] content in self?.sendClipboard(content) }
        dockTiles.onActivate = { [weak self] bundleID in
            self?.focusApp(bundleID)
        }
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeHosts()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        notifications.onOpen = { [weak self] id, bundleID in
            self?.openNotification(id: id, bundleID: bundleID)
        }
    }

    deinit {
        inputQueue.finish()
    }

    // MARK: - Pairing

    /// True once paired, even when the connection afterwards fails; that shows on the hosts list.
    @discardableResult
    func pair(address: String, port: Int = 7880, code: String) async -> Bool {
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
            return true
        } catch {
            notice = Self.friendly(error, host: nil)
            return false
        }
    }

    func forget(_ host: PairedHost) {
        if current?.publicKey == host.publicKey { Task { await disconnect() } }
        hosts.removeAll { $0.publicKey == host.publicKey }
        try? hostStore.save(hosts)
    }

    // MARK: - Connection

    func connect(_ host: PairedHost) async {
        // A second click while the first is still connecting.
        if case .connecting = state, reconnectTask == nil { return }
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
        try await registerStreamHandlers()
        current = host
        state = .connected(host.name)
        reachability[host.publicKey] = .online
        Task { await learnAbout(host) }
        if clipboardSyncEnabled { clipboard.start() }
    }

    func disconnect() async {
        userDisconnecting = true
        reconnectTask?.cancel()
        reconnectTask = nil
        clipboard.stop()
        for portal in portals.values { portal.close() }
        portals.removeAll()
        pendingTracks.removeAll()
        dockTiles.removeAll()
        await room.disconnect()
        current = nil
        apps = []
        hostLocked = false
        resetSound()
        state = .idle
    }

    /// The host went away or the network dropped: keep trying for a couple of minutes.
    private func scheduleReconnect(after error: LiveKitError?) {
        guard let host = current, !userDisconnecting else { return }
        reopenAfterReconnect = portals.values.map(\.info)
        for portal in portals.values { portal.hostClosed() }
        portals.removeAll()
        pendingTracks.removeAll()
        dockTiles.removeAll()
        clipboard.stop()
        apps = []
        hostLocked = false
        resetSound()
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
                    self.reconnectTask = nil
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
                    // Revoked on the host: retrying won't help.
                    if case PairingError.notTrusted = error {
                        self.giveUpReconnecting(Self.friendly(error, host: host))
                        return
                    }
                }
            }
            self?.giveUpReconnecting("Could not reconnect to \(host.name). Is Teleport still running there?")
        }
    }

    private func giveUpReconnecting(_ message: String) {
        reconnectTask = nil
        reopenAfterReconnect = []
        current = nil
        notice = nil
        state = .failed(message)
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

    private func sendClipboard(_ content: ClipboardSync.Content) {
        guard connected, clipboardSyncEnabled else { return }
        ClipboardSync.send(content, over: room)
    }

    func refresh() async {
        guard connected else { return }
        do {
            let reply = try await rpc(RPCMethod.apps, "{}")
            apps = try RPCReply.decode([AppInfo].self, from: reply)
            if !badges.isEmpty { applyBadges() }
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
        guard !opening.contains(window.id) else { return }
        opening.insert(window.id)
        defer { opening.remove(window.id) }
        do {
            let reply = try await rpc(RPCMethod.open, try OpenRequest(windowID: window.id).jsonString(), timeout: 20)
            let response = try RPCReply.decode(OpenResponse.self, from: reply)
            // Disconnected while the host was opening it.
            guard connected else { return }
            let portal = PortalWindowController(info: response.window, scale: response.scale, hostName: current?.name ?? "", viewer: self)
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

    /// Quits the app on the host; its portals close as its windows go.
    func quit(_ app: AppInfo, force: Bool) async {
        busy = true
        defer { busy = false }
        notice = nil
        do {
            let request = QuitRequest(bundleID: app.bundleID, force: force)
            let reply = try await rpc(RPCMethod.quit, try request.jsonString(), timeout: 15)
            let response = try RPCReply.decode(QuitResponse.self, from: reply)
            if !response.quit {
                notice = "\(app.name) is still running. It may be asking to save changes: open its window to answer, or use Force Quit."
            }
            await refresh()
        } catch {
            notice = "Could not quit \(app.name): \(Self.friendly(error, host: current))"
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

    // MARK: - Byte streams

    /// The room keeps handlers across reconnects, and registering one twice throws.
    private var streamHandlersRegistered = false

    private func registerStreamHandlers() async throws {
        guard !streamHandlersRegistered else { return }
        try await room.registerByteStreamHandler(for: Topic.clipboardImage) { [weak self] reader, _ in
            guard let self, await self.clipboardSyncEnabled else { return }
            await self.clipboard.receiveImage(reader)
        }
        try await room.registerByteStreamHandler(for: Topic.downloads) { [weak self] reader, _ in
            await self?.receiveDownload(reader)
        }
        streamHandlersRegistered = true
    }

    // MARK: - Host health

    /// Asks each paired host we aren't connected to whether it is there. Quick: an /info call with a short timeout.
    private func probeHosts() async {
        for host in hosts where host.publicKey != current?.publicKey {
            let info = try? await HostClient.info(address: host.address, port: host.port, timeout: 3)
            if let info, info.publicKey == host.publicKey {
                reachability[host.publicKey] = .online
                remember(info, for: host)
            } else {
                let lastSeen: Date? = if case let .offline(seen) = reachability[host.publicKey] { seen } else if reachability[host.publicKey] == .online { Date() } else { nil }
                reachability[host.publicKey] = .offline(lastSeen: lastSeen)
            }
        }
    }

    /// The connected host's version and wake details.
    private func learnAbout(_ host: PairedHost) async {
        guard let info = try? await HostClient.info(address: host.address, port: host.port, timeout: 5), info.publicKey == host.publicKey else { return }
        hostInfo = info
        remember(info, for: host)
    }

    /// Keeps the host's MAC address, so it can be woken later while it sleeps.
    private func remember(_ info: HostInfo, for host: PairedHost) {
        guard let mac = info.macAddress, let index = hosts.firstIndex(where: { $0.publicKey == host.publicKey }), hosts[index].macAddress != mac else { return }
        hosts[index].macAddress = mac
        try? hostStore.save(hosts)
    }

    /// Sends a Wake-on-LAN packet; only reaches a Mac on the same local network.
    func wake(_ host: PairedHost) {
        guard let mac = host.macAddress else { return }
        let sent = WakeOnLAN.send(to: mac)
        notice = sent ? "Sent a wake-up to \(host.name). It works on the same network, when it wakes for network access." : "Could not send a wake-up to \(host.name)."
        Log.info("wake-on-lan to \(host.name): \(sent ? "sent" : "failed")")
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await probeHosts()
        }
    }

    // MARK: - Downloads

    /// A file a shared app saved on the host: streamed to a temporary folder, then into Downloads
    /// under a name that doesn't overwrite anything, flagged as downloaded like any other download.
    private func receiveDownload(_ reader: ByteStreamReader) async {
        guard downloadsEnabled else { return }
        let name = FileNames.safe(reader.info.name)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let received = try await reader.writeToFile(in: staging, name: name)
            let target = FileNames.freeURL(in: FileNames.downloads, for: name)
            try FileManager.default.moveItem(at: received, to: target)
            Self.markDownloaded(target)
            let app = reader.info.attributes[DownloadKeys.app]
            Log.info("downloads: saved \(target.lastPathComponent) from \(app ?? "the host")")
            await notifications.showDownload(target, app: app, hostName: current?.name ?? "the host")
        } catch {
            Log.warn("downloads: could not save \(name): \(error)")
            notice = "Could not save \(name) from \(current?.name ?? "the host"): \(error.localizedDescription)"
        }
    }

    /// The quarantine flag, so Gatekeeper checks an app or script from the other Mac before it opens.
    private static func markDownloaded(_ url: URL) {
        let value = String(format: "0081;%08x;Teleport;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }

    // MARK: - Badges

    private func badgesChanged(_ new: [String: String]) {
        guard new != badges else { return }
        badges = new
        applyBadges()
    }

    /// An app with unread items gets a Dock tile with its count, even without a portal open;
    /// its tile goes again once the count is gone and no portal is open.
    private func applyBadges() {
        for (bundleID, label) in badges {
            dockTiles.setBadge(bundleID: bundleID, label)
            guard !dockTiles.hasTile(bundleID: bundleID), let app = apps.first(where: { $0.bundleID == bundleID }) else { continue }
            Task {
                guard let icon = await loadIcon(for: bundleID), connected, badges[bundleID] != nil else { return }
                dockTiles.ensureTile(bundleID: bundleID, appName: app.name, icon: icon)
            }
        }
        for app in apps where badges[app.bundleID] == nil {
            dockTiles.setBadge(bundleID: app.bundleID, nil)
            if dockTiles.hasTile(bundleID: app.bundleID), !portals.values.contains(where: { $0.info.bundleID == app.bundleID }) {
                dockTiles.removeTile(bundleID: app.bundleID)
            }
        }
    }

    // MARK: - Sound

    private func hostAudioArrived(_ track: RemoteAudioTrack) {
        hostAudio = track
        applyAudioVolume()
        Log.info("sound: receiving the host's app audio\(audioEnabled ? "" : " (muted in settings)")")
    }

    private func applyAudioVolume() {
        hostAudio?.volume = audioEnabled ? 1 : 0
    }

    private func hostStatusChanged(_ status: HostStatus) {
        hostLocked = status.locked
        let wanted = status.microphoneWanted ?? false
        guard wanted != hostWantsMicrophone else { return }
        hostWantsMicrophone = wanted
        updateMicrophone()
    }

    /// Sends the microphone while the setting is on and a shared app on the host listens to one;
    /// otherwise unpublishes it, which lets go of the microphone (and its indicator) here.
    private func updateMicrophone() {
        let wanted = connected && microphoneEnabled && hostWantsMicrophone
        let previous = microphoneQueue
        microphoneQueue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let live = self.microphonePublication != nil
            guard wanted != live else { return }
            do {
                if wanted {
                    self.microphonePublication = try await self.room.localParticipant.setMicrophone(
                        enabled: true, publishOptions: AudioPublishOptions(name: TrackName.microphone)
                    )
                    Log.info("sound: microphone on; an app on the host is listening")
                } else if let publication = self.microphonePublication {
                    self.microphonePublication = nil
                    try await self.room.localParticipant.unpublish(publication: publication)
                    Log.info("sound: microphone off")
                }
            } catch {
                Log.warn("sound: microphone \(wanted ? "on" : "off") failed: \(error)")
                if wanted { self.notice = "Could not use the microphone: \(error). Check System Settings › Privacy & Security › Microphone." }
            }
            self.microphoneLive = self.microphonePublication != nil
        }
    }

    /// The room is gone, and its tracks with it.
    private func resetSound() {
        badges = [:]
        hostInfo = nil
        hostAudio = nil
        hostWantsMicrophone = false
        microphonePublication = nil
        microphoneLive = false
    }

    // MARK: - Notifications

    private func showNotification(_ notification: RemoteNotification) async {
        guard notificationsEnabled else { return }
        let icon = await loadIcon(for: notification.bundleID)
        await notifications.show(notification, icon: icon)
    }

    /// A notification was clicked: click it on the host too, so the app goes to what it is about,
    /// then bring that app's portal forward, or open one.
    func openNotification(id: String, bundleID: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard connected else { return }
        Task {
            // A host before notifications doesn't know this call; the app still comes forward below.
            if let payload = try? ShowNotificationRequest(id: id, bundleID: bundleID).jsonString() {
                _ = try? await rpc(RPCMethod.showNotification, payload, timeout: 10)
            }
            await refresh()
            focusApp(bundleID)
        }
    }

    func portalClosed(_ windowID: UInt32) {
        guard let portal = portals.removeValue(forKey: windowID) else { return }
        fireAndForget(RPCMethod.close, CloseRequest(windowID: windowID))
        let bundleID = portal.info.bundleID
        if !portals.values.contains(where: { $0.info.bundleID == bundleID }), badges[bundleID] == nil {
            dockTiles.removeTile(bundleID: bundleID)
        }
    }

    func requestResize(_ windowID: UInt32, to size: CGSize) {
        fireAndForget(RPCMethod.resize, ResizeRequest(windowID: windowID, width: size.width, height: size.height))
    }

    func send(_ event: InputEvent) {
        guard connected, let data = try? JSONEncoder().encode(event) else { return }
        inputQueue.yield(data)
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
        guard let icon = await remoteIcon(bundleID) else { return nil }
        icons[bundleID] = icon
        return icon
    }

    /// 256 px, enough for a Dock tile on a Retina screen. It takes several replies; a host
    /// before 0.3 ignores the size and sends one small PNG.
    private func remoteIcon(_ bundleID: String) async -> NSImage? {
        func part(_ index: Int) async -> IconResponse? {
            guard let payload = try? IconRequest(bundleID: bundleID, size: 256, part: index).jsonString(),
                  let reply = try? await rpc(RPCMethod.icon, payload)
            else { return nil }
            return try? RPCReply.decode(IconResponse.self, from: reply)
        }
        guard let first = await part(0) else { return nil }
        var encoded = first.png
        for index in 1 ..< max(1, first.parts ?? 1) {
            guard let next = await part(index) else { return nil }
            encoded += next.png
        }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }

    private func trackArrived(_ track: RemoteVideoTrack, name: String) {
        guard let id = TrackName.windowID(from: name) else { return }
        if let portal = portals[id] {
            portal.attach(track: track)
        } else {
            pendingTracks[name] = track
        }
    }

    private func trackLeft(name: String, sid: Track.Sid?) {
        if pendingTracks[name]?.sid == sid { pendingTracks.removeValue(forKey: name) }
        guard let id = TrackName.windowID(from: name), let portal = portals[id] else { return }
        // A portal closed and reopened at once gets a new track under the same name; the old
        // one's unsubscribe must not close it.
        if let attached = portal.trackSid, attached != sid { return }
        portal.hostClosed()
        portalClosed(id)
    }
}

extension ViewerController: RoomDelegate {
    nonisolated func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if let audio = publication.track as? RemoteAudioTrack {
            Task { @MainActor in self.hostAudioArrived(audio) }
            return
        }
        guard let track = publication.track as? RemoteVideoTrack else { return }
        let name = publication.name
        Task { @MainActor in self.trackArrived(track, name: name) }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        let name = publication.name
        let sid = publication.sid
        Task { @MainActor in self.trackLeft(name: name, sid: sid) }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType _: EncryptionType) {
        switch topic {
        case Topic.clipboard:
            Task { @MainActor in
                guard self.clipboardSyncEnabled, let message = try? JSONDecoder().decode(ClipboardMessage.self, from: data) else { return }
                self.clipboard.apply(message.text)
            }
        case Topic.badges:
            Task { @MainActor in
                guard let message = try? JSONDecoder().decode(AppBadges.self, from: data) else { return }
                self.badgesChanged(message.badges)
            }
        case Topic.notifications:
            Task { @MainActor in
                guard let notification = try? JSONDecoder().decode(RemoteNotification.self, from: data) else { return }
                await self.showNotification(notification)
            }
        case Topic.hostStatus:
            Task { @MainActor in
                guard let status = try? JSONDecoder().decode(HostStatus.self, from: data) else { return }
                self.hostStatusChanged(status)
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
