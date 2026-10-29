import Combine
import SwiftUI
import TeleportCore

/// The host's window: status, pairing, paired Macs and the shared apps.
struct HostView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var host: HostController
    @Local private var showAddApp = false
    @Local private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                permissionNotices
                pairingCard
                if !host.trusted.isEmpty { devicesCard }
                appsCard
            }
            .padding(20)
        }
        .onReceive(tick) { now = $0 }
        .alert(item: Binding(get: { host.pendingApproval }, set: { _ in })) { pending in
            Alert(
                title: Text("Allow \(pending.name) to use this Mac's apps?"),
                message: Text("The other Mac shows the same code: \(pending.fingerprint). If it doesn't, press Deny."),
                primaryButton: .default(Text("Allow")) { host.approvePairing() },
                secondaryButton: .cancel(Text("Deny")) { host.denyPairing() }
            )
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(host.config.deviceName).font(.title2.weight(.semibold))
                        statusPill
                    }
                    if host.state == .hosting {
                        Text(host.viewers.isEmpty ? "No viewer connected." : "\(host.viewers.count) viewer\(host.viewers.count == 1 ? "" : "s") connected, \(host.openPortals.count) window\(host.openPortals.count == 1 ? "" : "s") open.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if case let .failed(message) = host.state {
                        Text(message).font(.callout).foregroundStyle(Theme.bad)
                    }
                }
                Spacer()
                switch host.state {
                case .hosting: Button("Stop") { Task { await host.stop() } }
                case .stopped, .failed: Button("Start") { Task { await host.start() } }.primaryAction()
                case .starting: ProgressView().controlSize(.small)
                }
            }
            if !host.addresses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reach this Mac at").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(host.addresses, id: \.self) { CopyChip(text: $0) }
                        Chip(text: "port \(host.config.port)", mono: true)
                    }
                }
            }
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
            Notice(text: "Screen Recording is off. Teleport can't stream windows without it.", kind: .warning,
                   action: ("Open System Settings", { SystemSettings.open("Privacy_ScreenCapture") }))
        }
        if !host.hasAccessibility {
            Notice(text: "Accessibility is off. Viewers can see windows but not click or type.", kind: .warning,
                   action: ("Open System Settings", { SystemSettings.open("Privacy_Accessibility") }))
        }
    }

    // MARK: - Pairing

    private var pairingCard: some View {
        Card(title: "Pair a Mac", subtitle: "On the other Mac, choose Pair a new Mac and type this code.") {
            if let pairing = host.pairingCode {
                HStack(alignment: .center, spacing: 20) {
                    CodeDisplay(code: pairing.code)
                    VStack(alignment: .leading, spacing: 6) {
                        let left = max(0, Int(pairing.expires.timeIntervalSince(now)))
                        Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))").font(.callout).foregroundStyle(.secondary)
                        if host.pendingApproval != nil {
                            Text("Waiting for you to allow…").font(.callout).foregroundStyle(Theme.remote)
                        }
                        Button("Cancel") { host.cancelPairing() }.controlSize(.small)
                    }
                }
            } else {
                Button("Show pairing code") { host.startPairing() }
                    .primaryAction()
                    .disabled(host.state != .hosting)
            }
        }
    }

    private var devicesCard: some View {
        Card(title: "Paired Macs") {
            ForEach(host.trusted) { device in
                HStack {
                    Image(systemName: "laptopcomputer").foregroundStyle(Theme.remote)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.body.weight(.medium))
                        Text(lastSeen(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Chip(text: String(device.publicKey.prefix(8)), mono: true)
                    Button("Revoke") { host.revoke(device) }.controlSize(.small)
                }
                if device.id != host.trusted.last?.id { Divider() }
            }
        }
    }

    private func lastSeen(_ device: TrustedDevice) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        if let seen = device.lastSeen { return "Last connected \(formatter.localizedString(for: seen, relativeTo: now))" }
        return "Paired \(formatter.localizedString(for: device.pairedAt, relativeTo: now))"
    }

    // MARK: - Apps

    private var sharedApps: [(bundleID: String, installed: InstalledApp?)] {
        host.config.allowedApps.map { id in (id, host.installedApps.first { $0.bundleID == id }) }
    }

    private var appsCard: some View {
        Card(title: "Shared apps", subtitle: "Viewers only see and open windows of these apps.") {
            if sharedApps.isEmpty {
                EmptyState(icon: "square.grid.2x2", title: "Nothing shared yet", detail: "Add the apps viewers may use. Everything else stays private.")
            } else {
                ForEach(sharedApps, id: \.bundleID) { entry in
                    HStack(spacing: 10) {
                        AppIconView(image: entry.installed.map(InstalledApps.icon(for:)), size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.installed?.name ?? entry.bundleID)
                            if entry.installed == nil {
                                Text("Not installed on this Mac").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove") { host.setAllowed(entry.bundleID, false) }.controlSize(.small)
                    }
                    if entry.bundleID != sharedApps.last?.bundleID { Divider() }
                }
            }
            Button { showAddApp = true } label: { Label("Add app", systemImage: "plus") }
        }
        .sheet(isPresented: $showAddApp) { AddAppSheet(host: host) }
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
                Text("Add an app to share").font(.title3.weight(.semibold))
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
