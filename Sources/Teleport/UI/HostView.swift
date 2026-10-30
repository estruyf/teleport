import Combine
import ServiceManagement
import SwiftUI
import TeleportCore

/// The host's window: status, pairing, paired Macs and the shared apps.
struct HostView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var host: HostController
    @Local private var showAddApp = false
    @Local private var loginNotice: String?
    @Local private var loginStatus: SMAppService.Status = .notRegistered
    /// Picks up permissions granted in System Settings; the checks run off the main thread.
    private let permissionPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            BeamBackdrop(strength: host.state == .hosting ? 1 : 0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    permissionNotices
                    pairingCard
                    if !host.trusted.isEmpty { devicesCard }
                    appsCard
                    setupCard
                }
                .padding(20)
            }
        }
        .onReceive(permissionPoll) { _ in
            if !host.hasScreenRecording || !host.hasAccessibility { host.refreshPermissions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            host.refreshPermissions()
            refreshLoginStatus()
        }
        .onAppear { refreshLoginStatus() }
        .sheet(item: Binding(get: { host.pendingApproval }, set: { _ in })) { pending in
            AllowSheet(host: host, pending: pending)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        Card {
            HStack(spacing: 18) {
                PortalRing(mood: host.state == .hosting ? .live : (host.state == .starting ? .busy : .idle), size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(host.config.deviceName).font(.title.weight(.semibold))
                        statusPill
                    }
                    Text(heroLine).font(.callout).foregroundStyle(host.state.isFailed ? Theme.bad : .secondary)
                    if host.state == .hosting, !host.addresses.isEmpty {
                        HStack(spacing: 8) {
                            Text("Reach it at").font(.caption).foregroundStyle(.secondary)
                            ForEach(host.addresses, id: \.self) { CopyChip(text: $0) }
                            Chip(text: "port \(host.config.port)", mono: true)
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer()
                switch host.state {
                case .hosting: Button("Stop") { Task { await host.stop() } }
                case .stopped, .failed: Button("Start hosting") { Task { await host.start() } }.primaryAction()
                case .starting: ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var heroLine: String {
        switch host.state {
        case .hosting:
            if host.viewers.isEmpty { return "Ready. No Mac is looking at it right now." }
            let v = host.viewers.count, w = host.openPortals.count
            return "\(v) Mac\(v == 1 ? "" : "s") connected, \(w) window\(w == 1 ? "" : "s") open."
        case .starting: return "Starting the streaming server…"
        case .stopped: return "Not sharing anything."
        case let .failed(message): return message
        }
    }

    private var statusPill: some View {
        switch host.state {
        case .hosting: StatusPill(text: "Hosting", color: Theme.ok)
        case .starting: StatusPill(text: "Starting", color: Theme.warn)
        case .stopped: StatusPill(text: "Stopped", color: .gray)
        case .failed: StatusPill(text: "Failed", color: Theme.bad)
        }
    }

    @ViewBuilder private var permissionNotices: some View {
        if !host.hasScreenRecording {
            Notice(text: "Screen Recording is off, so nothing can be streamed. After switching it on, macOS asks to quit and reopen Teleport. That's normal.", kind: .warning,
                   action: ("Open System Settings", { SystemSettings.open("Privacy_ScreenCapture") }))
        }
        if !host.hasAccessibility {
            Notice(text: "Accessibility is off. Viewers can see windows but not click or type.", kind: .warning,
                   action: ("Open System Settings", { SystemSettings.open("Privacy_Accessibility") }))
        }
        if host.livekitMissing {
            Notice(text: "The streaming server (livekit-server) is missing. Rebuild the app with it bundled, or install it with Homebrew: brew install livekit.", kind: .error,
                   action: ("Try again", { Task { await host.start() } }))
        }
    }

    // MARK: - Pairing

    private var pairingCard: some View {
        Card(title: "Pair a Mac", subtitle: "On the other Mac, press Pair a new Mac and type this code.") {
            if let pairing = host.pairingCode {
                HStack(spacing: 24) {
                    CodeDisplay(code: pairing.code)
                    PairingCountdown(expires: pairing.expires)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(host.pendingApproval == nil ? "Waiting for the other Mac…" : "A Mac is asking. Check the code.")
                            .font(.callout).foregroundStyle(Theme.remote)
                        Button("Cancel") { host.cancelPairing() }.controlSize(.small)
                    }
                    Spacer()
                }
            } else {
                HStack {
                    Button {
                        host.startPairing()
                    } label: {
                        Label("Show pairing code", systemImage: "link.badge.plus")
                    }
                    .primaryAction()
                    .disabled(host.state != .hosting)
                    if host.state != .hosting {
                        Text("Start hosting first.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var devicesCard: some View {
        Card(title: "Paired Macs", subtitle: "These Macs may open the shared apps. Revoke ends their access at once.") {
            ForEach(host.trusted) { device in
                HStack {
                    Image(systemName: "laptopcomputer").foregroundStyle(Theme.remote)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.body.weight(.medium))
                        Text(lastSeen(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if host.viewers.contains(where: { $0.hasSuffix(String(device.publicKey.prefix(8))) }) {
                        StatusPill(text: "Connected", color: Theme.ok)
                    }
                    Chip(text: String(device.publicKey.prefix(8)), mono: true)
                    Button("Revoke", role: .destructive) { host.revoke(device) }.controlSize(.small)
                }
                if device.id != host.trusted.last?.id { Divider() }
            }
        }
    }

    private func lastSeen(_ device: TrustedDevice) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        if let seen = device.lastSeen { return "Last connected \(formatter.localizedString(for: seen, relativeTo: Date()))" }
        return "Paired \(formatter.localizedString(for: device.pairedAt, relativeTo: Date()))"
    }

    // MARK: - Apps

    private var sharedApps: [(bundleID: String, installed: InstalledApp?)] {
        host.config.allowedApps.map { id in (id, host.installedApps.first { $0.bundleID == id }) }
    }

    private var appsCard: some View {
        Card(title: "Shared apps", subtitle: "Viewers only see and open windows of these apps. Everything else stays private.") {
            if sharedApps.isEmpty {
                EmptyState(icon: "square.grid.2x2", title: "Nothing shared yet", detail: "Add the apps your other Macs may use.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(sharedApps, id: \.bundleID) { entry in
                        HStack(spacing: 10) {
                            AppIconView(image: entry.installed.map(InstalledApps.icon(for:)), size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.installed?.name ?? entry.bundleID).lineLimit(1)
                                if entry.installed == nil {
                                    Text("Not installed here").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { host.setAllowed(entry.bundleID, false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain).help("Stop sharing")
                        }
                        .padding(8)
                        .background(Theme.remote.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            Button { showAddApp = true } label: { Label("Add app", systemImage: "plus") }
        }
        .sheet(isPresented: $showAddApp) { AddAppSheet(host: host) }
    }

    // MARK: - Setup

    private var setupCard: some View {
        Card(title: "Keep it running") {
            Toggle(isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: { on in
                loginNotice = LoginItem.set(on)
                refreshLoginStatus()
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Teleport when this Mac logs in")
                    Text("So a reboot of the office Mac comes back hosting on its own.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if loginStatus == .requiresApproval {
                Notice(text: "macOS wants you to confirm this under Login Items.", kind: .info, action: ("Open Login Items", { SystemSettings.openLoginItems() }))
            }
            if let loginNotice { Notice(text: loginNotice, kind: .error) }
        }
    }

    /// SMAppService.status is an XPC round trip; never call it from `body`.
    private func refreshLoginStatus() {
        Task {
            let status = await Task.detached(priority: .utility) { LoginItem.status }.value
            if loginStatus != status { loginStatus = status }
        }
    }
}

/// The pairing code's remaining time. Ticks on its own so the rest of the window doesn't redraw every second.
private struct PairingCountdown: View {
    let expires: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, expires.timeIntervalSince(context.date))
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 5)
                Circle().trim(from: 0, to: left / 120)
                    .stroke(Theme.remote, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: left)
                Text("\(Int(left))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
        }
    }
}

/// The host decides whether a Mac that typed the code may connect.
private struct AllowSheet: View {
    @ObservedObject var host: HostController
    let pending: HostController.PendingApproval

    var body: some View {
        VStack(spacing: 22) {
            Text("Allow \(pending.name)?").font(.title2.weight(.semibold))
            HStack(spacing: 0) {
                MacGlyph(symbol: "laptopcomputer", label: pending.name, tint: Theme.remote)
                Rectangle().fill(Theme.remote.opacity(0.5)).frame(height: 2).frame(maxWidth: 120)
                    .overlay(Image(systemName: "arrow.left.arrow.right").font(.caption).foregroundStyle(Theme.remote).padding(6).background(.background, in: Circle()))
                MacGlyph(symbol: "macmini.fill", label: host.config.deviceName, tint: .primary)
            }
            VStack(spacing: 6) {
                Text("It shows this code too:").font(.callout).foregroundStyle(.secondary)
                Text(pending.fingerprint).font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(Theme.remote)
                Text("If the codes differ, someone is in between. Press Deny.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Deny", role: .cancel) { host.denyPairing() }.keyboardShortcut(.cancelAction)
                Button("Allow") { host.approvePairing() }.primaryAction().keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}

/// Pick an installed app to share.
private struct AddAppSheet: View {
    @ObservedObject var host: HostController
    @Environment(\.dismiss) private var dismiss
    @Local private var query = ""

    private var candidates: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return host.installedApps.filter { app in
            !host.isAllowed(app.bundleID) && (q.isEmpty || app.name.localizedCaseInsensitiveContains(q) || app.bundleID.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Share an app").font(.title3.weight(.semibold))
                Spacer()
                Button { host.rescanApps() } label: { Image(systemName: "arrow.clockwise") }.help("Rescan installed apps")
            }
            TextField("Search installed apps", text: $query).textFieldStyle(.roundedBorder)
            List(candidates) { app in
                Button {
                    host.setAllowed(app.bundleID, true)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        AppIconView(image: InstalledApps.icon(for: app), size: 26)
                        Text(app.name)
                        Spacer()
                        Text(app.bundleID).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 320)
            HStack {
                Text("Can't find it? Drop any .app here.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier else { return }
                    Task { @MainActor in
                        host.setAllowed(id, true)
                        host.rescanApps()
                        dismiss()
                    }
                }
            }
            return true
        }
    }
}
