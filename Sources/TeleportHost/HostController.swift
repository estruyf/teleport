import AppKit
import ApplicationServices
import LiveKit
import TeleportCore

/// Owns the host side: virtual display, LiveKit server, room connection and portals.
@MainActor
final class HostController: NSObject {
    static let identity = "teleport-host"

    private var config: TeleportConfig!
    private var virtualDisplay: VirtualDisplay?
    private var server: LiveKitServer!
    private let room = Room()
    private let injector = InputInjector()
    private var portals: [CGWindowID: Portal] = [:]
    private var activity: NSObjectProtocol?

    func start() async {
        do {
            config = try TeleportConfig.loadOrCreate()
            Log.info("config: \(TeleportConfig.fileURL.path)")
            checkPermissions()

            // Nobody sits at this Mac; keep it awake while hosting.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Teleport is hosting windows"
            )

            if config.virtualDisplay.enabled {
                startVirtualDisplay()
            }

            server = LiveKitServer(config: config)
            try await server.start()

            room.add(delegate: self)
            try await room.connect(
                url: server.signalURL,
                token: AccessToken.make(config: config, identity: Self.identity)
            )
            try await registerRPCs()
            Log.info("hosting on port \(config.port); allowed apps: \(config.allowedApps.joined(separator: ", "))")
        } catch {
            Log.error("host failed to start: \(error)")
            NSApp.terminate(nil)
        }
    }

    func stop() {
        server?.stop()
    }

    private func checkPermissions() {
        if !CGPreflightScreenCaptureAccess() {
            Log.warn("Screen Recording permission missing; requesting it (System Settings > Privacy & Security)")
            CGRequestScreenCaptureAccess()
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Log.warn("Accessibility permission missing; input and resizing won't work until it is granted")
        }
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

    // MARK: - RPC

    private func registerRPCs() async throws {
        try await room.registerRpcMethod(RPCMethod.list) { [weak self] _ in
            await RPCReply.wrap {
                guard let self else { throw HostError("host is shutting down") }
                return try await self.listWindows().jsonString()
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

    private func listWindows() async throws -> [WindowInfo] {
        try await WindowCatalog.list(allowedApps: config.allowedApps)
    }

    private func open(_ request: OpenRequest) async throws -> OpenResponse {
        if let existing = portals[request.windowID] {
            return OpenResponse(trackName: TrackName.forWindow(existing.windowID), window: existing.info)
        }
        var (window, display) = try await WindowCatalog.find(request.windowID)
        if let bundleID = window.owningApplication?.bundleIdentifier,
           !config.allowedApps.isEmpty, !config.allowedApps.contains(bundleID)
        {
            throw HostError("\(bundleID) is not in allowedApps")
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
        return OpenResponse(trackName: TrackName.forWindow(portal.windowID), window: portal.info)
    }

    private func close(_ windowID: CGWindowID) async {
        guard let portal = portals.removeValue(forKey: windowID) else { return }
        await portal.close(room: room)
    }

    private func resize(_ request: ResizeRequest) {
        portals[request.windowID]?.resize(to: CGSize(width: request.width, height: request.height))
    }

    fileprivate func handleInput(_ data: Data) {
        guard let event = try? JSONDecoder().decode(InputEvent.self, from: data),
              let portal = portals[event.windowID]
        else { return }
        injector.handle(event, portal: portal)
    }

    fileprivate func viewerLeft() async {
        // Stop capturing once the last viewer is gone.
        guard room.remoteParticipants.isEmpty else { return }
        for id in Array(portals.keys) {
            await close(id)
        }
    }
}

extension HostController: RoomDelegate {
    nonisolated func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType _: EncryptionType) {
        guard topic == Topic.input else { return }
        Task { @MainActor in self.handleInput(data) }
    }

    nonisolated func room(_: Room, participantDidConnect participant: RemoteParticipant) {
        Log.info("viewer joined: \(participant.identity?.stringValue ?? "?")")
    }

    nonisolated func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        Log.info("viewer left: \(participant.identity?.stringValue ?? "?")")
        Task { @MainActor in await self.viewerLeft() }
    }

    nonisolated func room(_: Room, didDisconnectWithError error: LiveKitError?) {
        Log.error("host disconnected from its own server: \(String(describing: error))")
    }
}
