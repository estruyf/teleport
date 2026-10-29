import AppKit
import SwiftUI
import TeleportCore

/// Picker: host address, connect, and the remote apps with their windows.
struct PickerView: View {
    @ObservedObject var viewer: ViewerController
    @AppStorage("teleport.host") private var host = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Host (IP, hostname or Tailscale name)", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { connectOrDisconnect() }
                Button(viewer.connected ? "Disconnect" : "Connect") { connectOrDisconnect() }
                    .disabled(host.isEmpty)
                Button("Refresh") { Task { await viewer.refresh() } }
                    .disabled(!viewer.connected)
            }
            Text(viewer.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)

            List {
                ForEach(viewer.apps) { app in
                    Section {
                        if app.windows.isEmpty {
                            Text(app.running ? "No windows" : "Not running")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        ForEach(app.windows) { window in
                            Button { Task { await viewer.open(window) } } label: {
                                HStack {
                                    Text(window.title.isEmpty ? "(untitled)" : window.title).lineLimit(1)
                                    Spacer()
                                    Text("\(Int(window.width))×\(Int(window.height))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        AppHeader(app: app, icon: viewer.icons[app.bundleID]) { newWindow in
                            Task { await viewer.launch(app, newWindow: newWindow) }
                        }
                    }
                }
            }
            .overlay {
                if viewer.connected, viewer.apps.isEmpty {
                    Text("No shareable apps. Check allowedApps on the host.").foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 420)
    }

    private func connectOrDisconnect() {
        Task {
            if viewer.connected {
                await viewer.disconnect()
            } else {
                await viewer.connect(to: host.trimmingCharacters(in: .whitespaces))
            }
        }
    }
}

struct AppHeader: View {
    let app: AppInfo
    let icon: NSImage?
    let launch: (_ newWindow: Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.dashed").frame(width: 24, height: 24)
            }
            Text(app.name).font(.headline)
            Circle().fill(app.running ? Color.green : Color.gray.opacity(0.4)).frame(width: 7, height: 7)
            Spacer()
            Button(app.running ? "New window" : "Launch") { launch(app.running) }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

@MainActor
final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    let viewer = ViewerController()
    private var picker: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Teleport"
        window.contentView = NSHostingView(rootView: PickerView(viewer: viewer))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        picker = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        picker?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    func applicationWillTerminate(_: Notification) {
        let semaphore = DispatchSemaphore(value: 0)
        Task { await viewer.disconnect(); semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}

Log.setup(role: "viewer")
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ViewerAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)

    // A minimal menu bar so ⌘Q works from the picker; portal windows swallow shortcuts themselves.
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Teleport", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    app.mainMenu = mainMenu

    app.run()
}
