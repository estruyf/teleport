import SwiftUI
import TeleportCore

/// The viewer's window: your Macs in the sidebar, the selected one on the right:
/// its apps while connected, otherwise what it takes to open a portal to it.
struct ViewerView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var viewer: ViewerController
    @StateObject private var browser = HostBrowser()
    @Local private var showPairSheet = false
    @Local private var pairPrefill: DiscoveredHost?
    /// The selected paired host, by public key. Nil picks the connected one, else the first.
    @Local private var selectedKey: String?

    var body: some View {
        ZStack {
            GlowBackdrop(strength: viewer.connected ? 1 : 0.6)
            if viewer.hosts.isEmpty {
                welcome
            } else {
                SidebarLayout {
                    sidebar
                } detail: {
                    detail
                }
            }
        }
        .sheet(isPresented: $showPairSheet) {
            PairSheet(viewer: viewer, browser: browser, prefill: pairPrefill)
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        // Follow the connection: connecting from the menu bar selects that Mac here too.
        .onChange(of: viewer.current?.publicKey) { _, key in if let key { selectedKey = key } }
    }

    private var selected: PairedHost? {
        if let selectedKey, let host = viewer.hosts.first(where: { $0.publicKey == selectedKey }) { return host }
        return viewer.current ?? viewer.hosts.first
    }

    private func isNearby(_ host: PairedHost) -> Bool {
        browser.hosts.contains { $0.keyPrefix == String(host.publicKey.prefix(16)) }
    }

    private var unpaired: [DiscoveredHost] {
        browser.hosts.filter { found in !viewer.hosts.contains { $0.publicKey.hasPrefix(found.keyPrefix) } }
    }

    private func pair(_ prefill: DiscoveredHost?) {
        pairPrefill = prefill
        showPairSheet = true
    }

    // MARK: - Sidebar

    @ViewBuilder private var sidebar: some View {
        SidebarHeading(text: "Your Macs")
        ForEach(viewer.hosts) { host in
            SidebarRow(icon: "macmini.fill", title: host.name, subtitle: status(of: host),
                       badge: viewer.current?.publicKey == host.publicKey && viewer.connected ? .live(viewer.openWindowIDs.count) : .none,
                       selected: selected?.publicKey == host.publicKey) {
                selectedKey = host.publicKey
            }
        }
        if !unpaired.isEmpty {
            SidebarHeading(text: "Nearby")
            ForEach(unpaired) { found in
                SidebarRow(icon: "macmini", title: found.name, subtitle: found.address.isEmpty ? "Resolving…" : "Not paired · \(found.source.rawValue)", selected: false) {
                    pair(found)
                }
                .disabled(found.address.isEmpty)
                .help("Pair with \(found.name)")
            }
        } else if browser.searching {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Looking nearby…").font(.caption).foregroundStyle(.secondary) }
                .padding(.horizontal, 8).padding(.top, 8)
        }
        Spacer()
        Button { pair(nil) } label: { Label("Pair a new Mac", systemImage: "plus").frame(maxWidth: .infinity) }
            .controlSize(.large)
    }

    private func status(of host: PairedHost) -> String {
        if viewer.current?.publicKey == host.publicKey {
            switch viewer.state {
            case .connected: return "Connected"
            case .connecting: return "Connecting…"
            default: break
            }
        }
        return isNearby(host) ? "Nearby" : host.address
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let host = selected {
            let isCurrent = viewer.current?.publicKey == host.publicKey
            switch viewer.state {
            case .connected where isCurrent: connectedView(host)
            case let .connecting(name) where name == host.name: connectingView(name)
            default: hostCard(host)
            }
        }
    }

    /// A paired Mac that isn't open: who it is, whether it's around, and the one button that matters.
    private func hostCard(_ host: PairedHost) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ZStack {
                PortalRing(mood: .idle, size: 120)
                Image(systemName: "macmini.fill").font(.system(size: 40)).foregroundStyle(Theme.remote)
            }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(host.name).font(.title.weight(.semibold))
                    if isNearby(host) { StatusPill(text: "Nearby", color: Theme.ok) }
                }
                Text("\(host.address) · port \(String(host.port)) · paired \(host.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if case let .failed(message) = viewer.state, selectedFailed(host) {
                Notice(text: message, kind: .error).frame(maxWidth: 460)
            } else if let notice = viewer.notice {
                Notice(text: notice, kind: notice.hasPrefix("Paired") ? .success : .info).frame(maxWidth: 460)
            }
            HStack(spacing: 10) {
                Button { Task { await viewer.connect(host) } } label: {
                    Label(viewer.connected ? "Switch to \(host.name)" : "Open portal", systemImage: "arrow.up.forward.app")
                        .padding(.horizontal, 8)
                }
                .primaryAction().controlSize(.large).keyboardShortcut(.defaultAction)
                Button("Forget", role: .destructive) { viewer.forget(host) }.controlSize(.large)
            }
            if viewer.connected, let current = viewer.current {
                Text("Opening it closes the portals from \(current.name).").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The failure belongs to the selected Mac when no other one is the current connection.
    private func selectedFailed(_ host: PairedHost) -> Bool {
        viewer.current == nil || viewer.current?.publicKey == host.publicKey
    }

    private func connectingView(_ name: String) -> some View {
        VStack(spacing: 18) {
            PortalRing(mood: .busy, size: 130)
            Text("Opening portal for \(name)…").font(.title2.weight(.semibold))
            Text(viewer.notice ?? "Connecting to \(name).").font(.callout).foregroundStyle(.secondary)
            Button("Cancel") { Task { await viewer.disconnect() } }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectedView(_ host: PairedHost) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Apps on \(host.name)").font(.title2.weight(.semibold))
                        StatusPill(text: "Connected", color: Theme.ok)
                    }
                    Text(connectedLine).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if viewer.busy { ProgressView().controlSize(.small) }
                Button { Task { await viewer.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button("Disconnect") { Task { await viewer.disconnect() } }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            if viewer.hostLocked {
                Notice(text: "\(host.name) is locked. Its windows still show, but typing and opening new windows won't work until you unlock it, for example with Screen Sharing.", kind: .warning)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            if let notice = viewer.notice {
                Notice(text: notice, kind: notice.hasPrefix("Could not") ? .error : .info)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            if viewer.apps.isEmpty {
                EmptyState(icon: "square.grid.2x2", title: "Nothing shared yet",
                           detail: "On \(host.name), add apps under Apps. They appear here right away.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(viewer.apps) { remoteApp in
                            RemoteAppCard(app: remoteApp, icon: viewer.icons[remoteApp.bundleID], busy: viewer.busy, openIDs: viewer.openWindowIDs) { newWindow in
                                Task { await viewer.launch(remoteApp, newWindow: newWindow) }
                            } open: { window in
                                Task { await viewer.open(window) }
                            } quit: { force in
                                Task { await viewer.quit(remoteApp, force: force) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var connectedLine: String {
        let running = viewer.apps.filter(\.running).count
        let open = viewer.openWindowIDs.count
        return "\(viewer.apps.count) shared, \(running) running · \(open) portal\(open == 1 ? "" : "s") open here · \(host(viewer.current))"
    }

    private func host(_ host: PairedHost?) -> String { host?.address ?? "" }

    // MARK: - First run

    /// No Mac paired yet: one screen that says what to do, with the Macs already found nearby.
    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            PortalRing(mood: browser.searching ? .busy : .idle, size: 110)
            VStack(spacing: 6) {
                Text("Pair the Mac whose apps you want here").font(.title2.weight(.semibold))
                Text("On that Mac, open Teleport as the host and press Show pairing code.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !unpaired.isEmpty {
                VStack(spacing: 8) {
                    ForEach(unpaired) { found in
                        HStack(spacing: 12) {
                            Image(systemName: "macmini").foregroundStyle(Theme.remote)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(found.name).font(.body.weight(.medium))
                                Text("\(found.address.isEmpty ? "resolving…" : found.address) · \(found.source.rawValue)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Pair") { pair(found) }.controlSize(.small).disabled(found.address.isEmpty)
                        }
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .frame(maxWidth: 420)
            } else if browser.searching {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for Macs nearby…").font(.caption).foregroundStyle(.secondary) }
            }
            if case let .failed(message) = viewer.state {
                Notice(text: message, kind: .error).frame(maxWidth: 420)
            }
            Button { pair(nil) } label: { Label("Pair a new Mac", systemImage: "plus").padding(.horizontal, 8) }
                .primaryAction().controlSize(.large)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RemoteAppCard: View {
    let app: AppInfo
    let icon: NSImage?
    let busy: Bool
    var openIDs: Set<UInt32> = []
    let launch: (_ newWindow: Bool) -> Void
    let open: (WindowInfo) -> Void
    let quit: (_ force: Bool) -> Void
    @Local private var confirmForceQuit = false

    var body: some View {
        Card(fillHeight: true) {
            HStack(spacing: 12) {
                AppIconView(image: icon, size: 40).shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(app.running ? Theme.ok : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                        Text(app.running ? (app.windows.isEmpty ? "Running, no windows" : "\(app.windows.count) window\(app.windows.count == 1 ? "" : "s")") : "Not running")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(app.running ? "New Window" : "Launch") { launch(app.running) }
                    .controlSize(.small)
                    .fixedSize()
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
                        WindowRow(window: window, isOpen: openIDs.contains(window.id)) { open(window) }
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
    var isOpen = false
    let open: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack {
                Image(systemName: "macwindow").foregroundStyle(.secondary)
                Text(window.title.isEmpty ? "Untitled" : window.title).lineLimit(1)
                Spacer()
                Text("\(Int(window.width))×\(Int(window.height))").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Image(systemName: isOpen ? "checkmark.circle.fill" : "arrow.up.forward.app").foregroundStyle(Theme.remote)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.remote.opacity(hovering ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOpen ? "Open in a portal here; click to bring it to the front" : "Open in a portal window")
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
                        // Paired but not connected: the hosts list behind the sheet says why.
                        if await viewer.pair(address: address.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 7880, code: code) { dismiss() }
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
