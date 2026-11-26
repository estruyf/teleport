import Combine
import ServiceManagement
import SwiftUI
import TeleportCore

/// The host's window: a sidebar of sections, each of which fits the window without scrolling.
/// Overview answers "is it working?" at a glance; the other sections hold the details.
struct HostView: View {
    enum Section: Hashable { case overview, apps, macs, running }

    @ObservedObject var app: AppModel
    @ObservedObject var host: HostController
    @Local private var section: Section = .overview
    @Local private var showAddApp = false
    @Local private var loginNotice: String?
    @Local private var loginStatus: SMAppService.Status = .notRegistered
    /// Picks up permissions granted in System Settings; the checks run off the main thread.
    private let permissionPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            GlowBackdrop(strength: host.state == .hosting ? 1 : 0.4)
            SidebarLayout {
                sidebarStatus
                SidebarHeading(text: "Host")
                SidebarRow(icon: "gauge.with.dots.needle.50percent", title: "Overview", badge: problems.isEmpty ? .none : .attention, selected: section == .overview) { section = .overview }
                SidebarRow(icon: "square.grid.2x2", title: "Apps", badge: .count(host.config.allowedApps.count), selected: section == .apps) { section = .apps }
                SidebarRow(icon: "laptopcomputer", title: "Paired Macs", badge: connectedDevices.isEmpty ? .count(host.trusted.count) : .live(connectedDevices.count), selected: section == .macs) { section = .macs }
                SidebarRow(icon: "bolt.shield", title: "Keep it running", badge: runningNeedsAttention ? .attention : .none, selected: section == .running) { section = .running }
                Spacer()
                sidebarFooter
            } detail: {
                Group {
                    switch section {
                    case .overview: overview
                    case .apps: appsSection
                    case .macs: macsSection
                    case .running: runningSection
                    }
                }
                .padding(20)
            }
        }
        .onReceive(permissionPoll) { _ in
            if !host.hasScreenRecording || !host.hasAccessibility { host.refreshPermissions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            host.refreshPermissions()
            host.refreshSignIn()
            refreshLoginStatus()
        }
        .onAppear {
            host.refreshSignIn()
            refreshLoginStatus()
        }
        .sheet(item: Binding(get: { host.pendingApproval }, set: { _ in })) { pending in
            AllowSheet(host: host, pending: pending)
        }
        .sheet(isPresented: $showAddApp) { AddAppSheet(host: host) }
    }

    // MARK: - Sidebar

    private var sidebarStatus: some View {
        HStack(spacing: 10) {
            PortalRing(mood: ringMood, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.config.deviceName).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    Text(stateText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var sidebarFooter: some View {
        switch host.state {
        case .hosting:
            Button { Task { await host.stop() } } label: { Label("Stop hosting", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                .controlSize(.large)
        case .stopped, .failed:
            Button { Task { await host.start() } } label: { Label("Start hosting", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .controlSize(.large).primaryAction()
        case .starting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity)
        }
    }

    private var ringMood: PortalRing.Mood { host.state == .hosting ? .live : (host.state == .starting ? .busy : .idle) }

    private var stateText: String {
        switch host.state {
        case .hosting: "Hosting"
        case .starting: "Starting"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    private var stateColor: Color {
        switch host.state {
        case .hosting: Theme.ok
        case .starting: Theme.warn
        case .stopped: .gray
        case .failed: Theme.bad
        }
    }

    // MARK: - Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusCard
            HStack(alignment: .top, spacing: 14) {
                pairingCard
                connectedCard
            }
            .fixedSize(horizontal: false, vertical: true)
            checklistCard
            Spacer(minLength: 0)
        }
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 16) {
                PortalRing(mood: ringMood, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text(host.config.deviceName).font(.title2.weight(.semibold))
                        StatusPill(text: stateText, color: stateColor)
                    }
                    Text(heroLine).font(.callout).foregroundStyle(host.state.isFailed ? Theme.bad : .secondary)
                    if host.state == .hosting, !host.addresses.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(host.addresses, id: \.self) { CopyChip(text: $0) }
                            Chip(text: "port \(host.config.port)", mono: true)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private var heroLine: String {
        switch host.state {
        case .hosting:
            if host.viewers.isEmpty { return "Ready. Other Macs can reach it at:" }
            let v = host.viewers.count, w = host.openPortals.count
            return "\(v) Mac\(v == 1 ? "" : "s") connected, \(w) window\(w == 1 ? "" : "s") open. Reachable at:"
        case .starting: return "Starting the streaming server…"
        case .stopped: return "Not sharing anything. Start hosting to let your other Macs in."
        case let .failed(message): return message
        }
    }

    private var pairingCard: some View {
        Card(title: "Pair a Mac", fillHeight: true) {
            pairingContent(compact: true)
        }
    }

    /// The code and its countdown while pairing is open, otherwise the button that opens it.
    @ViewBuilder private func pairingContent(compact: Bool) -> some View {
        if let pairing = host.pairingCode {
            VStack(alignment: .leading, spacing: 10) {
                CodeDisplay(code: pairing.code, compact: compact)
                HStack(spacing: 10) {
                    PairingCountdown(expires: pairing.expires, size: 30)
                    Text(host.pendingApproval == nil ? "Type it on the other Mac." : "A Mac is asking. Check the code.")
                        .font(.callout).foregroundStyle(Theme.remote)
                    Spacer()
                    Button("Cancel") { host.cancelPairing() }.controlSize(.small)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("On the other Mac, press Pair a new Mac, then type the code this shows.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { host.startPairing() } label: { Label("Show pairing code", systemImage: "link.badge.plus") }
                    .primaryAction()
                    .disabled(host.state != .hosting)
                if host.state != .hosting { Text("Start hosting first.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var connectedCard: some View {
        Card(title: "Connected now", fillHeight: true) {
            if connectedDevices.isEmpty {
                Text(host.trusted.isEmpty ? "No Mac is paired yet." : "No Mac is looking at it right now.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(connectedDevices) { device in
                    Label(device.name, systemImage: "laptopcomputer").foregroundStyle(.primary)
                }
                let windows = host.openPortals
                if !windows.isEmpty {
                    Divider()
                    ForEach(windows.prefix(3)) { window in
                        HStack(spacing: 6) {
                            Image(systemName: "macwindow").foregroundStyle(Theme.remote)
                            Text(window.title.isEmpty ? window.app : "\(window.app) · \(window.title)").lineLimit(1)
                        }
                        .font(.callout)
                    }
                    if windows.count > 3 { Text("and \(windows.count - 3) more").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    /// Everything that decides whether a viewer gets a working portal, with the fix next to each.
    private var checklistCard: some View {
        Card(title: "Ready to host?") {
            VStack(spacing: 2) {
                if host.livekitMissing {
                    CheckRow(state: .bad, title: "The streaming server is missing", detail: "Rebuild with it bundled, or brew install livekit.",
                             action: ("Try again", { Task { await host.start() } }))
                }
                CheckRow(state: host.hasScreenRecording ? .ok : .bad, title: "Screen Recording",
                         detail: host.hasScreenRecording ? nil : "Needed to stream. macOS then asks to quit and reopen Teleport.",
                         action: host.hasScreenRecording ? nil : ("Open Settings", { SystemSettings.open("Privacy_ScreenCapture") }))
                CheckRow(state: host.hasAccessibility ? .ok : .bad, title: "Accessibility",
                         detail: host.hasAccessibility ? nil : "Needed for viewers to click and type.",
                         action: host.hasAccessibility ? nil : ("Open Settings", { SystemSettings.open("Privacy_Accessibility") }))
                CheckRow(state: host.config.allowedApps.isEmpty ? .warn : .ok,
                         title: host.config.allowedApps.isEmpty ? "No apps shared yet" : "\(host.config.allowedApps.count) app\(host.config.allowedApps.count == 1 ? "" : "s") shared",
                         action: ("Manage", { section = .apps }))
                CheckRow(state: host.trusted.isEmpty ? .warn : .ok,
                         title: host.trusted.isEmpty ? "No Mac paired yet" : "\(host.trusted.count) Mac\(host.trusted.count == 1 ? "" : "s") paired",
                         action: ("Manage", { section = .macs }))
                CheckRow(state: comesBackAfterRestart ? .ok : .warn,
                         title: comesBackAfterRestart ? "Comes back after a restart" : "May not come back after a restart",
                         action: ("Review", { section = .running }))
            }
        }
    }

    /// What needs fixing before a viewer can use this host.
    private var problems: [String] {
        var list: [String] = []
        if host.livekitMissing { list.append("livekit") }
        if !host.hasScreenRecording { list.append("screen") }
        if !host.hasAccessibility { list.append("accessibility") }
        if host.state.isFailed { list.append("failed") }
        return list
    }

    private var connectedDevices: [TrustedDevice] {
        host.trusted.filter { device in host.viewers.contains { $0.hasSuffix(String(device.publicKey.prefix(8))) } }
    }

    // MARK: - Apps

    private var sharedApps: [(bundleID: String, installed: InstalledApp?)] {
        host.config.allowedApps.map { id in (id, host.installedApps.first { $0.bundleID == id }) }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Apps to teleport", subtitle: "Viewers only see and open windows of these apps. Everything else stays private.") {
                Button { showAddApp = true } label: { Label("Add app", systemImage: "plus") }.primaryAction()
            }
            if sharedApps.isEmpty {
                Card {
                    EmptyState(icon: "square.grid.2x2", title: "Nothing shared yet", detail: "Add the apps your other Macs may use. You can also drop an .app on the Add app sheet.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                        ForEach(sharedApps, id: \.bundleID) { entry in appTile(entry) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func appTile(_ entry: (bundleID: String, installed: InstalledApp?)) -> some View {
        let open = host.openPortals.filter { $0.bundleID == entry.bundleID }.count
        return HStack(spacing: 10) {
            AppIconView(image: entry.installed.map(InstalledApps.icon(for:)), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.installed?.name ?? entry.bundleID).font(.body.weight(.medium)).lineLimit(1)
                Group {
                    if entry.installed == nil {
                        Text("Not installed here").foregroundStyle(Theme.warn)
                    } else if open > 0 {
                        Text("\(open) window\(open == 1 ? "" : "s") in a portal").foregroundStyle(Theme.remote)
                    } else {
                        Text(entry.bundleID).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption).lineLimit(1)
            }
            Spacer()
            Button { host.setAllowed(entry.bundleID, false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain).help("Stop sharing")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    // MARK: - Paired Macs

    private var macsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Paired Macs", subtitle: "These Macs may open the shared apps. Revoke ends their access at once.") {
                if host.pairingCode == nil {
                    Button { host.startPairing() } label: { Label("Pair a Mac", systemImage: "link.badge.plus") }
                        .primaryAction().disabled(host.state != .hosting)
                }
            }
            if host.pairingCode != nil {
                Card(title: "Pairing code") { pairingContent(compact: false) }
            }
            if host.trusted.isEmpty {
                Card {
                    EmptyState(icon: "laptopcomputer", title: "No Mac paired yet",
                               detail: "Press Pair a Mac, then type the code on the other Mac under Pair a new Mac.")
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(host.trusted) { device in deviceRow(device) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func deviceRow(_ device: TrustedDevice) -> some View {
        let live = connectedDevices.contains(device)
        return HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").font(.title2).foregroundStyle(Theme.remote).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(device.name).font(.headline)
                    if live { StatusPill(text: "Connected", color: Theme.ok) }
                }
                Text(lastSeen(device)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: String(device.publicKey.prefix(8)), mono: true).help("The start of this Mac's key")
            Button("Revoke", role: .destructive) { host.revoke(device) }.controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func lastSeen(_ device: TrustedDevice) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        if let seen = device.lastSeen { return "Last connected \(formatter.localizedString(for: seen, relativeTo: Date()))" }
        return "Paired \(formatter.localizedString(for: device.pairedAt, relativeTo: Date()))"
    }

    // MARK: - Keep it running

    private var loginItemOn: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    private var comesBackAfterRestart: Bool {
        guard loginItemOn else { return false }
        guard let signIn = host.signIn else { return true }
        return signIn.signsInByItself
    }

    private var runningNeedsAttention: Bool { !comesBackAfterRestart }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Keep it running", subtitle: "For an office Mac nobody sits at: come back after a restart, and stay reachable.")
            Card {
                setting("Start Teleport when this Mac logs in", "A reboot comes back hosting on its own.", isOn: Binding(get: { loginItemOn }, set: { on in
                    loginNotice = LoginItem.set(on)
                    refreshLoginStatus()
                }))
                if loginStatus == .requiresApproval {
                    Notice(text: "macOS wants you to confirm this under Login Items.", kind: .info, action: ("Open Login Items", { SystemSettings.openLoginItems() }))
                }
                if let loginNotice { Notice(text: loginNotice, kind: .error) }
                Divider()
                setting("Keep this Mac from locking itself", "While hosting it counts as in use, so an idle-lock policy doesn't lock it. It can't unlock a locked Mac.",
                        isOn: Binding(get: { host.config.keepAliveEnabled }, set: { host.setKeepAlive($0) }))
                if host.config.keepAliveEnabled, !host.hasAccessibility {
                    Notice(text: "Keeping this Mac awake needs Accessibility.", kind: .warning,
                           action: ("Open System Settings", { SystemSettings.open("Privacy_Accessibility") }))
                }
            }
            if let signIn = host.signIn {
                Card(title: "After a restart") { afterRestart(signIn) }
            }
            if app.updater.isAvailable { HostUpdatesCard(updater: app.updater, idle: host.viewers.isEmpty) }
            Spacer(minLength: 0)
        }
    }

    /// Label on the left, switch on the right edge, so every switch in the section lines up.
    private func setting(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    /// Teleport only runs once someone is signed in, and can't sign in itself. Shows the one way that applies here.
    @ViewBuilder private func afterRestart(_ signIn: SignInSetup) -> some View {
        if signIn.signsInByItself {
            CheckRow(state: .ok, title: "Signs in as you by itself", detail: "Teleport starts hosting on its own after a restart.")
        } else if signIn.fileVault {
            CheckRow(state: .warn, title: "FileVault stops a restart at the password",
                     detail: "Someone has to type it at the Mac, or restart with sudo fdesetup authrestart, which skips it once. Then sign in through Screen Sharing.")
        } else if let other = signIn.autoLoginUser {
            CheckRow(state: .warn, title: "Signs in as \(other), not as you", detail: "Teleport only runs for whoever is signed in. Switch automatic login to your account.",
                     action: ("Users & Groups", { SystemSettings.openUsersAndGroups() }))
        } else {
            CheckRow(state: .info, title: "Nobody is signed in after a restart", detail: "Turn on automatic login, or sign in through Screen Sharing each time.",
                     action: ("Users & Groups", { SystemSettings.openUsersAndGroups() }))
        }
        // Also shown after an earlier opt-in on a Mac that signs in by itself, so it can be undone.
        if !signIn.signsInByItself || !signIn.relocks {
            Divider()
            setting("Stay unlocked after Screen Sharing",
                    "Otherwise closing Screen Sharing locks this Mac again, and viewers can't type into a locked Mac. Asks for an admin password.",
                    isOn: Binding(get: { !signIn.relocks }, set: { keepUnlocked in host.setScreenSharingRelock(!keepUnlocked) }))
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

/// How this host takes updates, and one that is waiting for the viewers to leave.
private struct HostUpdatesCard: View {
    @ObservedObject var updater: Updater
    let idle: Bool

    var body: some View {
        Card(title: "Updates") {
            HStack {
                if let pending = updater.pendingVersion {
                    CheckRow(state: .info, title: "Teleport \(pending) is ready",
                             detail: idle ? "Installing now." : "Installs as soon as no Mac is connected.")
                } else {
                    CheckRow(state: .ok, title: "Teleport \(TeleportVersion.string)",
                             detail: updater.automaticallyChecks ? "Updates install by themselves while no Mac is connected." : "Automatic checks are off (Settings).")
                }
                Button("Check Now") { updater.checkForUpdates() }.controlSize(.small).disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

/// The pairing code's remaining time. Ticks on its own so the rest of the window doesn't redraw every second.
private struct PairingCountdown: View {
    let expires: Date
    var size: CGFloat = 48

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, expires.timeIntervalSince(context.date))
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: size / 10)
                Circle().trim(from: 0, to: left / 120)
                    .stroke(Theme.remote, style: StrokeStyle(lineWidth: size / 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: left)
                Text("\(Int(left))").font(size < 40 ? .caption2.monospacedDigit() : .caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
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
