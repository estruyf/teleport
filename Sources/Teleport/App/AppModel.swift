import AppKit
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
    }

    private func activate(_ mode: TeleportConfig.Mode) {
        switch mode {
        case .host:
            let controller = HostController(config: config, identity: identity)
            // The host owns the config while it runs; mirror its edits.
            controller.$config.dropFirst().sink { [weak self] in self?.config = $0 }.store(in: &cancellables)
            controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
            host = controller
            NSApp.setActivationPolicy(.accessory)
            Task { await controller.start() }
        case .viewer:
            let controller = ViewerController(identity: identity, deviceName: config.deviceName)
            controller.clipboardSyncEnabled = config.clipboardSyncEnabled
            controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
            viewer = controller
            NSApp.setActivationPolicy(.regular)
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
        .frame(minWidth: 760, minHeight: 560)
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
                    Toggle("Sounds when a portal opens or a Mac pairs", isOn: $sounds)
                    TextField("Port", text: $port)
                }
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
        app.config = config
        app.host?.config = config
    }
}
