import AppKit
import TeleportCore

// Usage: TeleportDockTile --bundle-id <id> --icon <png path>
// The viewer copies this binary under the remote app's name, so the Dock shows that name.

@MainActor
final class TileDelegate: NSObject, NSApplicationDelegate {
    let bundleID: String
    let iconPath: String

    init(bundleID: String, iconPath: String) {
        self.bundleID = bundleID
        self.iconPath = iconPath
    }

    func applicationDidFinishLaunching(_: Notification) {
        if let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: DockTileIPC.quit, object: nil, queue: .main) { [bundleID] note in
            if note.userInfo?[DockTileIPC.bundleIDKey] as? String == bundleID {
                NSApp.terminate(nil)
            }
        }
        center.addObserver(forName: DockTileIPC.quitAll, object: nil, queue: .main) { _ in
            NSApp.terminate(nil)
        }
        // The viewer launched us because a portal opened; hand focus straight back to it.
        notifyViewer()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        notifyViewer()
        return false
    }

    func applicationDidBecomeActive(_: Notification) {
        notifyViewer()
    }

    private func notifyViewer() {
        DistributedNotificationCenter.default().postNotificationName(
            DockTileIPC.activate, object: nil,
            userInfo: [DockTileIPC.bundleIDKey: bundleID],
            deliverImmediately: true
        )
    }
}

let args = CommandLine.arguments
func value(for flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let bundleID = value(for: "--bundle-id"), let iconPath = value(for: "--icon") else {
    FileHandle.standardError.write(Data("usage: TeleportDockTile --bundle-id <id> --icon <png>\n".utf8))
    exit(2)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = TileDelegate(bundleID: bundleID, iconPath: iconPath)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
