import SwiftUI
import TeleportCore

/// The viewer's window: paired hosts, then the connected host's apps.
struct ViewerView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var viewer: ViewerController
    @Local private var showPairSheet = false

    var body: some View {
        Group {
            if viewer.connected {
                connectedView
            } else {
                hostsView
            }
        }
        .sheet(isPresented: $showPairSheet) { PairSheet(viewer: viewer) }
    }

    // MARK: - Hosts

    private var hostsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let notice = viewer.notice {
                    Notice(text: notice, kind: notice.lowercased().contains("fail") || notice.lowercased().contains("could not") ? .error : .info)
                }
                if case let .failed(message) = viewer.state {
                    Notice(text: message, kind: .error)
                }
                HStack {
                    Text("Your Macs").font(.title2.weight(.semibold))
                    Spacer()
                    Button { showPairSheet = true } label: { Label("Pair a new Mac", systemImage: "plus") }.primaryAction()
                }
                if viewer.hosts.isEmpty {
                    Card {
                        EmptyState(icon: "macmini", title: "No paired Mac yet",
                                   detail: "On the host Mac, open Teleport and choose Show pairing code. Then pair it here.")
                    }
                } else {
                    ForEach(viewer.hosts) { host in
                        HostRow(host: host, connecting: viewer.state == .connecting(host.name)) {
                            Task { await viewer.connect(host) }
                        } forget: {
                            viewer.forget(host)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Connected

    private var connectedView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "macmini").foregroundStyle(Theme.remote)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewer.current?.name ?? "").font(.headline)
                    Text(viewer.current?.address ?? "").font(.caption).foregroundStyle(.secondary)
                }
                StatusPill(text: "Connected", color: Theme.ok)
                Spacer()
                if viewer.busy { ProgressView().controlSize(.small) }
                Button { Task { await viewer.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button("Disconnect") { Task { await viewer.disconnect() } }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = viewer.notice { Notice(text: notice, kind: .info) }
                    if viewer.apps.isEmpty {
                        EmptyState(icon: "square.grid.2x2", title: "No shared apps", detail: "Switch apps on in the host's Shared apps list.")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(viewer.apps) { remoteApp in
                                RemoteAppCard(app: remoteApp, icon: viewer.icons[remoteApp.bundleID], busy: viewer.busy) { newWindow in
                                    Task { await viewer.launch(remoteApp, newWindow: newWindow) }
                                } open: { window in
                                    Task { await viewer.open(window) }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }
}

private struct HostRow: View {
    let host: PairedHost
    let connecting: Bool
    let connect: () -> Void
    let forget: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "macmini").font(.title2).foregroundStyle(Theme.remote)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.headline)
                    Text("\(host.address) · paired \(host.pairedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Forget", role: .destructive, action: forget).controlSize(.small)
                if connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Connect", action: connect).primaryAction()
                }
            }
        }
    }
}

private struct RemoteAppCard: View {
    let app: AppInfo
    let icon: NSImage?
    let busy: Bool
    let launch: (_ newWindow: Bool) -> Void
    let open: (WindowInfo) -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                AppIconView(image: icon, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(app.running ? Theme.ok : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                        Text(app.running ? (app.windows.isEmpty ? "Running, no windows" : "\(app.windows.count) window\(app.windows.count == 1 ? "" : "s")") : "Not running")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(app.running ? "New window" : "Launch") { launch(app.running) }
                    .controlSize(.small)
                    .disabled(busy)
            }
            if !app.windows.isEmpty {
                Divider()
                ForEach(app.windows) { window in
                    Button { open(window) } label: {
                        HStack {
                            Image(systemName: "macwindow").foregroundStyle(.secondary)
                            Text(window.title.isEmpty ? "Untitled" : window.title).lineLimit(1)
                            Spacer()
                            Text("\(Int(window.width))×\(Int(window.height))").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(Theme.remote)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Address and code entry for pairing with a host.
private struct PairSheet: View {
    @ObservedObject var viewer: ViewerController
    @Environment(\.dismiss) private var dismiss
    @Local private var address = ""
    @Local private var port = "7880"
    @Local private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair a new Mac").font(.title2.weight(.semibold))
            Text("On the host, open Teleport and choose Show pairing code.").foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Address").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("IP, hostname or Tailscale name", text: $address).textFieldStyle(.roundedBorder)
                    TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(width: 70)
                }
                Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                TextField("6 digits", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                    .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
            }

            if let fingerprint = viewer.pairingFingerprint {
                Notice(text: "Waiting for the host to allow. It shows the code \(fingerprint); make sure it matches.", kind: .info)
            } else if let notice = viewer.notice, viewer.busy == false {
                Notice(text: notice, kind: notice.hasPrefix("Paired") ? .info : .error)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(viewer.busy ? "Pairing…" : "Pair") {
                    Task {
                        await viewer.pair(address: address.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 7880, code: code)
                        if viewer.connected { dismiss() }
                    }
                }
                .primaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(viewer.busy || address.isEmpty || code.count != 6)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
