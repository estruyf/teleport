import AppKit
import ApplicationServices
import CryptoKit
import LiveKit
import TeleportCore

/// Owns the host side: virtual display, LiveKit server, control endpoint, pairing and portals.
@MainActor
final class HostController: NSObject, ObservableObject {
    static let identity = "teleport-host"

    enum State: Equatable {
        case stopped, starting, hosting, failed(String)
    }

    struct PairingCode: Equatable {
        let code: String
        let expires: Date
    }

    struct PendingApproval: Identifiable {
        let id = UUID()
        let name: String
        let fingerprint: String
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var addresses: [String] = []
    @Published private(set) var pairingCode: PairingCode?
    @Published private(set) var pendingApproval: PendingApproval?
    @Published private(set) var trusted: [TrustedDevice] = []
    @Published private(set) var viewers: [String] = []
    @Published private(set) var openPortals: [WindowInfo] = []
    @Published private(set) var installedApps: [InstalledApp] = []
    @Published private(set) var hasScreenRecording = CGPreflightScreenCaptureAccess()
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()
    /// livekit-server could not be found when starting.
    @Published private(set) var livekitMissing = false
    @Published var config: TeleportConfig {
        didSet { try? config.save() }
    }

    let identity: DeviceIdentity
    private var virtualDisplay: VirtualDisplay?
    private var server: LiveKitServer?
    private var control: ControlServer?
    private let room = Room()
    private let injector = InputInjector()
    private let bonjour = BonjourAdvertiser()
    private let clipboard = ClipboardSync()
    private var portals: [CGWindowID: Portal] = [:]
    private var activity: NSObjectProtocol?
    private let trustStore = JSONListStore<TrustedDevice>(filename: "trust.json")
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var usedNonces: Set<String> = []
    private var failedPairAttempts = 0
    private var codeTimer: Timer?

    init(config: TeleportConfig, identity: DeviceIdentity) {
        self.config = config
        self.identity = identity
        super.init()
        trusted = trustStore.load()
    }

    // MARK: - Lifecycle

    func start() async {
        guard state == .stopped || state.isFailed else { return }
        state = .starting
        livekitMissing = false
        do {
            checkPermissions()
            refreshPermissions()
            addresses = NetworkAddresses.current()
            installedApps = InstalledApps.scan()

            // Nobody sits at this Mac; keep it awake while hosting.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Teleport is hosting windows"
            )

            if config.virtualDisplay.enabled, virtualDisplay == nil {
                startVirtualDisplay()
            }

            let server = LiveKitServer(config: config)
            server.onUnexpectedExit = { [weak self] in
                Task { @MainActor in await self?.recoverFromServerExit() }
            }
            try await server.start()
            self.server = server

            let control = ControlServer { [weak self] method, path, body in
                await self?.handleControl(method: method, path: path, body: body) ?? (500, Data())
            }
            try control.start(port: config.controlPort)
            self.control = control

            room.add(delegate: self)
            try await room.connect(
                url: server.signalURL,
                token: AccessToken.make(config: config, identity: Self.identity)
            )
            try await registerRPCs()
            try await room.registerByteStreamHandler(for: Topic.files) { [weak self] reader, _ in
                await self?.receiveFile(reader)
            }
            bonjour.start(name: config.deviceName, port: config.port, publicKey: identity.publicKeyHex)
            clipboard.onChange = { [weak self] text in self?.broadcastClipboard(text) }
            state = .hosting
            Log.info("hosting on port \(config.port); allowed apps: \(config.allowedApps.joined(separator: ", "))")
        } catch {
            Log.error("host failed to start: \(error)")
            livekitMissing = "\(error)".contains("livekit-server not found")
            state = .failed(livekitMissing ? "The streaming server is missing." : "\(error)")
            server?.stop()
            control?.stop()
        }
    }

    func stop() async {
        for id in Array(portals.keys) { await close(id) }
        clipboard.stop()
        bonjour.stop()
        await room.disconnect()
        control?.stop()
        control = nil
        server?.stop()
        server = nil
        state = .stopped
    }

    /// Synchronous shutdown for signal handlers and app termination.
    func stopNow() {
        bonjour.stop()
        control?.stop()
        server?.stop()
    }

    /// livekit-server died on its own: start over. Viewers reconnect by themselves.
    private func recoverFromServerExit() async {
        guard state == .hosting else { return }
        Log.warn("livekit-server died; restarting the host")
        server = nil
        await stop()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await start()
    }

    // MARK: - Clipboard

    private func broadcastClipboard(_ text: String) {
        guard config.clipboardSyncEnabled, !room.remoteParticipants.isEmpty,
              let data = try? JSONEncoder().encode(ClipboardMessage(text: text)) else { return }
        Task { try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: Topic.clipboard, reliable: true)) }
    }

    private func applyClipboard(_ data: Data) {
        guard config.clipboardSyncEnabled, let message = try? JSONDecoder().decode(ClipboardMessage.self, from: data) else { return }
        clipboard.apply(message.text)
    }

    private func checkPermissions() {
        if !CGPreflightScreenCaptureAccess() {
            Log.warn("Screen Recording permission missing; requesting it")
            CGRequestScreenCaptureAccess()
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Log.warn("Accessibility permission missing; input and resizing won't work until it is granted")
        }
    }

    /// Re-checks both permissions off the main thread; the TCC lookups can take tens of ms.
    func refreshPermissions() {
        Task.detached(priority: .utility) { [weak self] in
            let screen = CGPreflightScreenCaptureAccess()
            let accessibility = AXIsProcessTrusted()
            await self?.applyPermissions(screen: screen, accessibility: accessibility)
        }
    }

    private func applyPermissions(screen: Bool, accessibility: Bool) {
        if hasScreenRecording != screen { hasScreenRecording = screen }
        if hasAccessibility != accessibility { hasAccessibility = accessibility }
    }

    private func startVirtualDisplay() {
        let vd = config.virtualDisplay
        guard let display = VirtualDisplay(widthPoints: vd.width, heightPoints: vd.height, hiDPI: vd.hiDPI) else {
            Log.error("could not create the virtual display")
            return
        }
        virtualDisplay = display
        // The display shows up asynchronously; pick the HiDPI mode once it's there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { display.selectMode() }
    }

    // MARK: - Settings

    func setAllowed(_ bundleID: String, _ allowed: Bool) {
        var apps = config.allowedApps
        if allowed { if !apps.contains(bundleID) { apps.append(bundleID) } } else { apps.removeAll { $0 == bundleID } }
        config.allowedApps = apps
    }

    func isAllowed(_ bundleID: String) -> Bool { config.allowedApps.contains(bundleID) }

    func rescanApps() { installedApps = InstalledApps.scan() }

    // MARK: - Pairing

    func startPairing() {
        let code = PairingCrypto.pairingCode()
        pairingCode = PairingCode(code: code, expires: Date().addingTimeInterval(120))
        failedPairAttempts = 0
        codeTimer?.invalidate()
        codeTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPairing() }
        }
        Log.info("pairing code issued")
    }

    func cancelPairing() {
        pairingCode = nil
        codeTimer?.invalidate()
        codeTimer = nil
        if pendingApproval != nil { resolveApproval(false) }
    }

    func approvePairing() { resolveApproval(true) }
    func denyPairing() { resolveApproval(false) }

    private func resolveApproval(_ allowed: Bool) {
        approvalContinuation?.resume(returning: allowed)
        approvalContinuation = nil
        pendingApproval = nil
    }

    func revoke(_ device: TrustedDevice) {
        trusted.removeAll { $0.publicKey == device.publicKey }
        try? trustStore.save(trusted)
        // Drop any live connection from that device.
        for participant in room.remoteParticipants.values {
            if participant.identity?.stringValue.hasSuffix(String(device.publicKey.prefix(8))) == true {
                Task { try? await room.localParticipant.performRpc(destinationIdentity: participant.identity!, method: RPCMethod.kick, payload: "{}") }
            }
        }
    }

    private func handleControl(method: String, path: String, body: Data) async -> (Int, Data) {
        func json(_ value: some Encodable, _ status: Int = 200) -> (Int, Data) {
            (status, (try? JSONEncoder().encode(value)) ?? Data())
        }
        switch (method, path) {
        case ("GET", ControlPath.info):
            return json(HostInfo(name: config.deviceName, publicKey: identity.publicKeyHex, version: TeleportVersion.string, port: config.port))

        case ("POST", ControlPath.pair):
            guard let request = try? JSONDecoder().decode(PairRequest.self, from: body) else { return json(ControlError("bad request"), 400) }
            guard let pairing = pairingCode, pairing.expires > Date() else { return json(ControlError("pairing is not open"), 410) }
            guard pendingApproval == nil else { return json(ControlError("another pairing is waiting"), 429) }
            guard let key = try? PairingCrypto.key(identity, theirPublicHex: request.viewerKey, salt: pairing.code, info: PairingCrypto.pairInfo),
                  let payload = try? PairingCrypto.open(PairPayload.self, request.box, with: key),
                  payload.viewerKey == request.viewerKey
            else {
                failedPairAttempts += 1
                if failedPairAttempts >= 5 { cancelPairing() }
                return json(ControlError("wrong code"), 403)
            }
            let fingerprint = PairingCrypto.fingerprint(request.viewerKey, identity.publicKeyHex, key: key)
            pendingApproval = PendingApproval(name: payload.viewerName, fingerprint: fingerprint)
            NSApp.requestUserAttention(.criticalRequest)
            let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                approvalContinuation = continuation
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    guard let self, self.approvalContinuation != nil else { return }
                    self.resolveApproval(false)
                }
            }
            guard allowed else { return json(ControlError("denied"), 403) }
            trusted.removeAll { $0.publicKey == request.viewerKey }
            trusted.append(TrustedDevice(name: payload.viewerName, publicKey: request.viewerKey))
            try? trustStore.save(trusted)
            cancelPairing()
            Log.info("paired with \(payload.viewerName)")
            guard let box = try? PairingCrypto.seal(PairResult(hostName: config.deviceName), with: key) else { return json(ControlError("seal failed"), 500) }
            return json(PairResponse(box: box))

        case ("POST", ControlPath.token):
            guard let request = try? JSONDecoder().decode(TokenRequest.self, from: body) else { return json(ControlError("bad request"), 400) }
            guard let index = trusted.firstIndex(where: { $0.publicKey == request.viewerKey }) else { return json(ControlError("not paired"), 401) }
            guard let key = try? PairingCrypto.key(identity, theirPublicHex: request.viewerKey, salt: "", info: PairingCrypto.sessionInfo),
                  let payload = try? PairingCrypto.open(TokenPayload.self, request.box, with: key)
            else { return json(ControlError("bad token request"), 401) }
            guard abs(Int(Date().timeIntervalSince1970) - payload.timestamp) < 60, !usedNonces.contains(payload.nonce) else {
                return json(ControlError("replay"), 409)
            }
            usedNonces.insert(payload.nonce)
            if usedNonces.count > 1000 { usedNonces.removeAll() }
            trusted[index].lastSeen = Date()
            try? trustStore.save(trusted)
            let viewerIdentity = "viewer-\(request.viewerKey.prefix(8))"
            let token = AccessToken.make(config: config, identity: viewerIdentity, ttl: 3600)
            let result = TokenResult(token: token, url: "", room: config.room, hostIdentity: Self.identity)
            guard let box = try? PairingCrypto.seal(result, with: key) else { return json(ControlError("seal failed"), 500) }
            return json(TokenResponse(box: box))

        default:
            return json(ControlError("not found"), 404)
        }
    }

    // MARK: - RPC

    private func registerRPCs() async throws {
        try await room.registerRpcMethod(RPCMethod.list) { [weak self] _ in
            await RPCReply.wrap {
                guard let self else { throw HostError("host is shutting down") }
                return try await WindowCatalog.list(allowedApps: self.config.allowedApps).jsonString()
            }
        }
        try await room.registerRpcMethod(RPCMethod.open) { [weak self] data in
            await RPCReply.wrap {
                guard let self else { throw HostError("host is shutting down") }
                let request = try OpenRequest.fromJSON(data.payload)
                return try await self.open(request).jsonString()
            }
        }
        try await room.registerRpcMethod(RPCMethod.close) { [weak self] data in
            await RPCReply.wrap {
                let request = try CloseRequest.fromJSON(data.payload)
                await self?.close(request.windowID)
                return "{}"
            }
        }
        try await room.registerRpcMethod(RPCMethod.resize) { [weak self] data in
            await RPCReply.wrap {
                let request = try ResizeRequest.fromJSON(data.payload)
                await self?.resize(request)
                return "{}"
            }
        }
        try await room.registerRpcMethod(RPCMethod.apps) { [weak self] _ in
            await RPCReply.wrap {
                guard let self else { throw HostError("host is shutting down") }
                return try await AppCatalog.list(allowedApps: self.config.allowedApps).jsonString()
            }
        }
        try await room.registerRpcMethod(RPCMethod.launch) { [weak self] data in
            await RPCReply.wrap {
                guard let self else { throw HostError("host is shutting down") }
                let request = try LaunchRequest.fromJSON(data.payload)
                return try await AppCatalog.launch(request, allowedApps: self.config.allowedApps, injector: self.injector).jsonString()
            }
        }
        try await room.registerRpcMethod(RPCMethod.icon) { data in
            await RPCReply.wrap {
                let request = try IconRequest.fromJSON(data.payload)
                return try await AppCatalog.icon(bundleID: request.bundleID).jsonString()
            }
        }
    }

    private func open(_ request: OpenRequest) async throws -> OpenResponse {
        if let existing = portals[request.windowID] {
            return OpenResponse(trackName: TrackName.forWindow(existing.windowID), window: existing.info)
        }
        var (window, display) = try await WindowCatalog.find(request.windowID)
        if let bundleID = window.owningApplication?.bundleIdentifier, !config.allowedApps.contains(bundleID) {
            throw HostError("\(bundleID) is not in the allowed apps")
        }

        // Keep shared windows on the Stage so they render at Retina density.
        if let stage = virtualDisplay, display.displayID != stage.displayID,
           let pid = window.owningApplication?.processID
        {
            let stageBounds = CGDisplayBounds(stage.displayID)
            AXWindow.setPosition(pid: pid, windowID: window.windowID, origin: CGPoint(x: stageBounds.minX + 40, y: stageBounds.minY + 40))
            try await Task.sleep(nanoseconds: 300_000_000)
            (window, display) = try await WindowCatalog.find(request.windowID)
        }

        let portal = try await Portal.open(window: window, display: display, room: room)
        portal.onGone = { [weak self] portal in
            Task { await self?.close(portal.windowID) }
        }
        portals[portal.windowID] = portal
        openPortals = portals.values.map(\.info)
        return OpenResponse(trackName: TrackName.forWindow(portal.windowID), window: portal.info)
    }

    private func close(_ windowID: CGWindowID) async {
        guard let portal = portals.removeValue(forKey: windowID) else { return }
        await portal.close(room: room)
        openPortals = portals.values.map(\.info)
    }

    private func resize(_ request: ResizeRequest) {
        portals[request.windowID]?.resize(to: CGSize(width: request.width, height: request.height))
    }

    private func handleInput(_ data: Data) {
        guard let event = try? JSONDecoder().decode(InputEvent.self, from: data),
              let portal = portals[event.windowID]
        else { return }
        injector.handle(event, portal: portal)
    }

    /// A file dropped on a portal: save it, then drag it into the window.
    private func receiveFile(_ reader: ByteStreamReader) async {
        let info = reader.info
        let name = (info.name ?? "file").components(separatedBy: "/").last ?? "file"
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Teleport", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(name)
            try await reader.readAll().write(to: target, options: .atomic)
            Log.info("received \(name) (\(info.totalLength ?? 0) bytes)")
            guard let idText = info.attributes[FileDropKeys.windowID], let windowID = UInt32(idText),
                  let portal = portals[windowID],
                  let x = Double(info.attributes[FileDropKeys.x] ?? ""), let y = Double(info.attributes[FileDropKeys.y] ?? "")
            else { return }
            let point = CGPoint(x: portal.frame.minX + x * portal.frame.width, y: portal.frame.minY + y * portal.frame.height)
            portal.focus()
            try await Task.sleep(nanoseconds: 150_000_000)
            FileDrop.perform(file: target, at: point)
        } catch {
            Log.warn("file receive failed: \(error)")
        }
    }

    private func viewerLeft() async {
        viewers = room.remoteParticipants.values.compactMap { $0.identity?.stringValue }
        // Stop capturing once the last viewer is gone.
        guard room.remoteParticipants.isEmpty else { return }
        clipboard.stop()
        for id in Array(portals.keys) { await close(id) }
    }

    private func viewerJoined() {
        viewers = room.remoteParticipants.values.compactMap { $0.identity?.stringValue }
        if config.clipboardSyncEnabled { clipboard.start() }
    }
}

extension HostController.State {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

extension HostController: RoomDelegate {
    nonisolated func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType _: EncryptionType) {
        switch topic {
        case Topic.input: Task { @MainActor in self.handleInput(data) }
        case Topic.clipboard: Task { @MainActor in self.applyClipboard(data) }
        default: break
        }
    }

    nonisolated func room(_: Room, participantDidConnect participant: RemoteParticipant) {
        Log.info("viewer joined: \(participant.identity?.stringValue ?? "?")")
        Task { @MainActor in self.viewerJoined() }
    }

    nonisolated func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        Log.info("viewer left: \(participant.identity?.stringValue ?? "?")")
        Task { @MainActor in await self.viewerLeft() }
    }

    nonisolated func room(_: Room, didDisconnectWithError error: LiveKitError?) {
        Log.error("host disconnected from its own server: \(String(describing: error))")
    }
}
