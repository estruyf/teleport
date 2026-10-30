import SwiftUI
import TeleportCore

/// The viewer's window: paired hosts, then the connected host's apps.
struct ViewerView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var viewer: ViewerController
    @StateObject private var browser = HostBrowser()
    @Local private var showPairSheet = false
    @Local private var pairPrefill: DiscoveredHost?

    var body: some View {
        ZStack {
            BeamBackdrop(strength: viewer.connected ? 1 : 0.6)
            switch viewer.state {
            case .connected: connectedView
            case let .connecting(name): connectingView(name)
            default: hostsView
            }
        }
        .sheet(isPresented: $showPairSheet) {
            PairSheet(viewer: viewer, browser: browser, prefill: pairPrefill)
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    // MARK: - Hosts

    private var hostsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    PortalRing(mood: .idle, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Macs").font(.title.weight(.semibold))
                        Text(viewer.hosts.isEmpty ? "Pair the Mac whose apps you want here." : "Pick a Mac to teleport its apps here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { pairPrefill = nil; showPairSheet = true } label: { Label("Pair a new Mac", systemImage: "plus") }.primaryAction()
                }
                .padding(.bottom, 4)

                if case let .failed(message) = viewer.state {
                    Notice(text: message, kind: .error)
                } else if let notice = viewer.notice {
                    Notice(text: notice, kind: notice.hasPrefix("Paired") ? .success : .info)
                }

                ForEach(viewer.hosts) { host in
                    HostRow(host: host, online: browser.hosts.contains { $0.keyPrefix == String(host.publicKey.prefix(16)) }) {
                        Task { await viewer.connect(host) }
                    } forget: {
                        viewer.forget(host)
                    }
                }

                let unpaired = browser.hosts.filter { found in !viewer.hosts.contains { $0.publicKey.hasPrefix(found.keyPrefix) } }
                if !unpaired.isEmpty || browser.searching {
                    Card(title: "Found nearby", subtitle: "Macs running Teleport on this network or your tailnet.") {
                        ForEach(unpaired) { found in
                            HStack(spacing: 12) {
                                Image(systemName: "macmini").foregroundStyle(Theme.remote)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(found.name).font(.body.weight(.medium))
                                    Text("\(found.address.isEmpty ? "resolving…" : found.address) · \(found.source.rawValue)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Pair") { pairPrefill = found; showPairSheet = true }.controlSize(.small).disabled(found.address.isEmpty)
                            }
                        }
                        if browser.searching, unpaired.isEmpty {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }

                if viewer.hosts.isEmpty, unpaired.isEmpty, !browser.searching {
                    Card {
                        EmptyState(icon: "macmini", title: "No Mac yet",
                                   detail: "On the host Mac, open Teleport and press Show pairing code. Then pair it here.")
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Connecting

    private func connectingView(_ name: String) -> some View {
        VStack(spacing: 18) {
            PortalRing(mood: .busy, size: 150)
            Text("Opening portal for \(name)…").font(.title2.weight(.semibold))
            Text(viewer.notice ?? "Connecting to \(name).").font(.callout).foregroundStyle(.secondary)
            Button("Cancel") { Task { await viewer.disconnect() } }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connected

    private var connectedView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                PortalRing(mood: .live, size: 36)
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
                    if viewer.hostLocked {
                        Notice(text: "\(viewer.current?.name ?? "The host") is locked. Its windows still show, but typing and opening new windows won't work until you unlock it, for example with Screen Sharing.", kind: .warning)
                    }
                    if let notice = viewer.notice { Notice(text: notice, kind: notice.hasPrefix("Could not") ? .error : .info) }
                    if viewer.apps.isEmpty {
                        EmptyState(icon: "square.grid.2x2", title: "Nothing shared yet",
                                   detail: "On \(viewer.current?.name ?? "the host"), add apps under Apps to teleport. They appear here right away.")
                    } else {
                        Text("Apps on \(viewer.current?.name ?? "the host")").font(.title3.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(viewer.apps) { remoteApp in
                                RemoteAppCard(app: remoteApp, icon: viewer.icons[remoteApp.bundleID], busy: viewer.busy) { newWindow in
                                    Task { await viewer.launch(remoteApp, newWindow: newWindow) }
                                } open: { window in
                                    Task { await viewer.open(window) }
                                } quit: { force in
                                    Task { await viewer.quit(remoteApp, force: force) }
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
    let online: Bool
    let connect: () -> Void
    let forget: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "macmini.fill").font(.title2).foregroundStyle(Theme.remote)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(host.name).font(.headline)
                        if online { StatusPill(text: "Nearby", color: Theme.ok) }
                    }
                    Text("\(host.address) · paired \(host.pairedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Forget", role: .destructive, action: forget).controlSize(.small)
                Button(action: connect) { Label("Open portal", systemImage: "arrow.up.forward.app") }.primaryAction()
            }
        }
        .hoverOutline()
    }
}

private struct RemoteAppCard: View {
    let app: AppInfo
    let icon: NSImage?
    let busy: Bool
    let launch: (_ newWindow: Bool) -> Void
    let open: (WindowInfo) -> Void
    let quit: (_ force: Bool) -> Void
    @Local private var confirmForceQuit = false

    var body: some View {
        Card(fillHeight: true) {
            HStack(spacing: 12) {
                AppIconView(image: icon, size: 48).shadow(color: .black.opacity(0.2), radius: 4, y: 2)
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
                if app.running {
                    Menu("Quit") {
                        Button("Force Quit…") { confirmForceQuit = true }
                    } primaryAction: {
                        quit(false)
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(busy)
                    .help("Quit \(app.name) on the host")
                }
            }
            Divider()
            VStack(spacing: 2) {
                if app.windows.isEmpty {
                    // Same shape as a window row, so every card keeps one height.
                    HStack {
                        Image(systemName: "macwindow")
                        Text("No open windows")
                        Spacer()
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                } else {
                    ForEach(app.windows) { window in
                        WindowRow(window: window) { open(window) }
                    }
                }
            }
            .padding(.horizontal, -8)
        }
        .confirmationDialog("Force quit \(app.name) on the host?", isPresented: $confirmForceQuit) {
            Button("Force Quit", role: .destructive) { quit(true) }
        } message: {
            Text("Unsaved changes in \(app.name) are lost.")
        }
    }
}

/// One remote window; the row itself is the button, highlighted under the pointer.
private struct WindowRow: View {
    let window: WindowInfo
    let open: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack {
                Image(systemName: "macwindow").foregroundStyle(.secondary)
                Text(window.title.isEmpty ? "Untitled" : window.title).lineLimit(1)
                Spacer()
                Text("\(Int(window.width))×\(Int(window.height))").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Image(systemName: "arrow.up.forward.app").foregroundStyle(Theme.remote)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.remote.opacity(hovering ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open in a portal window")
    }
}

/// Address and code entry for pairing with a host.
private struct PairSheet: View {
    @ObservedObject var viewer: ViewerController
    @ObservedObject var browser: HostBrowser
    let prefill: DiscoveredHost?
    @Environment(\.dismiss) private var dismiss
    @Local private var address = ""
    @Local private var port = "7880"
    @Local private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PortalRing(mood: viewer.busy ? .busy : .idle, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair a new Mac").font(.title2.weight(.semibold))
                    Text("On the host, press Show pairing code.").foregroundStyle(.secondary)
                }
            }

            if !browser.hosts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Found nearby").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(browser.hosts) { found in
                            Button {
                                address = found.address
                                port = String(found.port)
                                codeFocused = true
                            } label: {
                                Label(found.name, systemImage: "macmini")
                            }
                            .buttonStyle(.bordered)
                            .tint(address == found.address ? Theme.remote : nil)
                            .disabled(found.address.isEmpty)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Address").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("IP, hostname or Tailscale name", text: $address).textFieldStyle(.roundedBorder)
                    TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(width: 70)
                }
                Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                CodeEntry(code: $code, focused: $codeFocused)
            }

            if let fingerprint = viewer.pairingFingerprint {
                Notice(text: "Waiting for the host to allow. It shows \(fingerprint); make sure it matches.", kind: .info)
            } else if let notice = viewer.notice, !viewer.busy {
                Notice(text: notice, kind: notice.hasPrefix("Paired") ? .success : .error)
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
        .frame(width: 460)
        .onAppear {
            if let prefill {
                address = prefill.address
                port = String(prefill.port)
            }
            // With the address known, the code is the only thing left to type. Focus
            // set while the sheet is still appearing gets lost, hence the hop.
            if !address.isEmpty { DispatchQueue.main.async { codeFocused = true } }
        }
    }
}
