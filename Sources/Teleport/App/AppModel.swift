import AppKit
import AVFoundation
import Combine
import SwiftUI
import TeleportCore

/// The app's state: which mode this Mac is in and the controller for it.
@MainActor
final class AppModel: ObservableObject {
    @Published var config: TeleportConfig {
        didSet {
            try? config.save()
            applyFlags()
        }
    }
    @Published private(set) var host: HostController?
    @Published private(set) var viewer: ViewerController?

    let identity: DeviceIdentity
    let updater = Updater()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        config = TeleportConfig.loadOrCreate()
        identity = (try? DeviceIdentity.loadOrCreate()) ?? DeviceIdentity(privateKey: .init())
        applyFlags()
        if let mode = config.mode { activate(mode) }
    }

    /// Set while services stop, for the overlay that covers the window meanwhile.
    @Published private(set) var stoppingMessage: String?
    /// The mode being switched to, so the pickers don't jump back while the old one stops.
    @Published private(set) var switchingTo: TeleportConfig.Mode?

    var isRunning: Bool { host != nil || viewer != nil }

    func setMode(_ mode: TeleportConfig.Mode) {
        guard stoppingMessage == nil, config.mode != mode || !isRunning else { return }
        switchingTo = mode
        Task {
            await shutdown(message: "Stopping \(config.mode == .host ? "hosting" : "the viewer")…")
            config.mode = mode
            activate(mode)
            switchingTo = nil
        }
    }

    private func applyFlags() {
        Sounds.enabled = config.soundsEnabled
        viewer?.clipboardSyncEnabled = config.clipboardSyncEnabled
        viewer?.notificationsEnabled = config.notificationsEnabled
        viewer?.audioEnabled = config.audioEnabled
        viewer?.microphoneEnabled = config.microphoneEnabled
    }

    private func activate(_ mode: TeleportConfig.Mode) {
        switch mode {
        case .host:
            let controller = HostController(config: config, identity: identity)
            // The host owns the config while it runs; mirror its edits.
            controller.$config.dropFirst().sink { [weak self] in self?.config = $0 }.store(in: &cancellables)
            controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
            host = controller
            // A downloaded update installs only while no viewer is connected.
            controller.$viewers.sink { [weak self] in self?.updater.hostIsIdle($0.isEmpty) }.store(in: &cancellables)
            NSApp.setActivationPolicy(.accessory)
            updater.configure(for: .host)
            Task { await controller.start() }
        case .viewer:
            let controller = ViewerController(identity: identity, deviceName: config.deviceName)
            controller.clipboardSyncEnabled = config.clipboardSyncEnabled
            controller.notificationsEnabled = config.notificationsEnabled
            controller.audioEnabled = config.audioEnabled
            controller.microphoneEnabled = config.microphoneEnabled
            controller.videoTuning = config.videoTuning
            HostController.logVideoTuning(config.videoTuning)
            controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
            viewer = controller
            NSApp.setActivationPolicy(.regular)
            updater.configure(for: .viewer)
        }
    }

    /// Stops the running mode without blocking the main thread; livekit-server can take seconds to exit.
    func shutdown(message: String) async {
        guard isRunning else { return }
        stoppingMessage = message
        defer { stoppingMessage = nil }
        if let host { await host.stop() }
        if let viewer { await viewer.disconnect() }
        cancellables.removeAll()
        host = nil
        viewer = nil
    }

    /// Synchronous last resort for signals, or a quit whose shutdown(message:) got stuck.
    /// A viewer's room isn't left cleanly here: its disconnect needs the main thread we'd be blocking.
    func terminate() {
        host?.stopNow()
    }
}

/// Switches between the welcome screen and the mode's view.
struct RootView: View {
    @ObservedObject var app: AppModel
    @Local private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if app.config.mode != nil { header }
            Group {
                if let host = app.host {
                    HostView(app: app, host: host)
                } else if let viewer = app.viewer {
                    ViewerView(app: app, viewer: viewer)
                } else {
                    WelcomeView(app: app)
                }
            }
        }
        .frame(minWidth: 840, minHeight: 600)
        .overlay {
            if let message = app.stoppingMessage { StoppingOverlay(message: message) }
        }
        .animation(.easeInOut(duration: 0.2), value: app.stoppingMessage)
        .sheet(isPresented: $showSettings) { SettingsSheet(app: app) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
            Text("Teleport").font(.headline)
            Spacer()
            Picker("", selection: Binding(get: { app.switchingTo ?? app.config.mode ?? .viewer }, set: { app.setMode($0) })) {
                Text("Host").tag(TeleportConfig.Mode.host)
                Text("Viewer").tag(TeleportConfig.Mode.viewer)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .help("Host shares this Mac's apps. Viewer uses another Mac's apps.")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SettingsSheet: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Local private var name = ""
    @Local private var port = ""
    @Local private var vdEnabled = true
    @Local private var vdWidth = ""
    @Local private var vdHeight = ""
    @Local private var clipboard = true
    @Local private var sounds = false
    @Local private var notifications = true
    @Local private var audio = true
    @Local private var microphone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.weight(.semibold))
            Form {
                Section("This Mac") {
                    TextField("Name", text: $name)
                    Picker("Role", selection: Binding(get: { app.switchingTo ?? app.config.mode ?? .viewer }, set: { app.setMode($0) })) {
                        Text("Host: shares its apps").tag(TeleportConfig.Mode.host)
                        Text("Viewer: uses another Mac's apps").tag(TeleportConfig.Mode.viewer)
                    }
                }
                Section("Between Macs") {
                    Toggle("Share clipboard text", isOn: $clipboard)
                    Toggle(isOn: $notifications) {
                        Text("Notifications from shared apps")
                        Text(app.config.mode == .host
                            ? "Sends the banners of the apps you share to the connected Mac. Other apps' notifications stay here."
                            : "Shows the host's notifications from the apps it shares. Click one to open that app.")
                    }
                    Toggle("Sounds when a portal opens or a Mac pairs", isOn: $sounds)
                    TextField("Port", text: $port)
                }
                if app.config.mode == .viewer { Section("Sound") { soundSettings } }
                if app.config.mode == .host {
                    Section("Virtual display") {
                        Toggle("Create a display for a Mac without a screen", isOn: $vdEnabled)
                        HStack {
                            TextField("Width", text: $vdWidth)
                            Text("×")
                            TextField("Height", text: $vdHeight)
                            Text("points, Retina").foregroundStyle(.secondary)
                        }
                        .disabled(!vdEnabled)
                    }
                }
                if app.updater.isAvailable { UpdatesSection(updater: app.updater, mode: app.config.mode) }
                Section("This Mac's key") {
                    Text(app.identity.publicKeyHex).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Files live in \(TeleportConfig.directory.path)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Port and display changes apply after Stop and Start.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }.primaryAction().keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            name = app.config.deviceName
            port = String(app.config.port)
            vdEnabled = app.config.virtualDisplay.enabled
            vdWidth = String(app.config.virtualDisplay.width)
            vdHeight = String(app.config.virtualDisplay.height)
            clipboard = app.config.clipboardSyncEnabled
            sounds = app.config.soundsEnabled
            notifications = app.config.notificationsEnabled
            audio = app.config.audioEnabled
            microphone = app.config.microphoneEnabled
        }
    }

    /// The viewer's sound settings; a host has a Sound section in its window.
    @ViewBuilder private var soundSettings: some View {
        Toggle(isOn: $audio) {
            Text("Play the shared apps' sound")
            Text("Teams ringing, a video, the other side of a call.")
        }
        Toggle(isOn: $microphone) {
            Text("Send this Mac's microphone to shared apps")
            Text("Only while a shared app on the host listens to a microphone, such as during a call. The host needs a virtual audio device; the Sound section in its window shows how to set one up.")
        }
    }

    private func save() {
        var config = app.config
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { config.deviceName = name }
        if let p = Int(port), (1024 ... 65000).contains(p) { config.port = p }
        config.virtualDisplay.enabled = vdEnabled
        if let w = Int(vdWidth), w >= 800 { config.virtualDisplay.width = w }
        if let h = Int(vdHeight), h >= 600 { config.virtualDisplay.height = h }
        config.clipboardSync = clipboard
        config.sounds = sounds
        config.notifications = notifications
        // A host's sound settings live in the Sound section of its window and change there.
        if app.config.mode == .viewer {
            config.audio = audio
            // Ask now, while Teleport is in front: the microphone is first used when a call starts, maybe in the background.
            if microphone, !app.config.microphoneEnabled, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            config.microphone = microphone
        }
        app.config = config
        app.host?.config = config
    }
}

private struct UpdatesSection: View {
    @ObservedObject var updater: Updater
    let mode: TeleportConfig.Mode?

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Teleport \(TeleportVersion.string)")
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
            }
        }
    }

    private var detail: String {
        if let pending = updater.pendingVersion { return "\(pending) is downloaded and installs when no Mac is connected." }
        let last = updater.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "Not checked yet."
        return mode == .host ? "\(last) A host installs updates by itself while no Mac is connected." : last
    }
}
