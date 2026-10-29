import AppKit
import TeleportCore

/// Gives every remote app its own Dock icon by running one `TeleportDockTile`
/// stub per app, named after the app and carrying its badged icon.
@MainActor
final class DockTileManager {
    private var tiles: [String: Process] = [:]
    private var observer: NSObjectProtocol?

    /// Called when the user clicks a tile; the viewer brings that app's portals forward.
    var onActivate: ((String) -> Void)?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: DockTileIPC.activate, object: nil, queue: .main
        ) { [weak self] note in
            guard let bundleID = note.userInfo?[DockTileIPC.bundleIDKey] as? String else { return }
            MainActor.assumeIsolated { self?.onActivate?(bundleID) }
        }
    }

    func ensureTile(bundleID: String, appName: String, icon: NSImage) {
        if let existing = tiles[bundleID], existing.isRunning { return }
        guard let stub = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("TeleportDockTile"),
              FileManager.default.isExecutableFile(atPath: stub.path)
        else {
            Log.warn("TeleportDockTile binary not found next to the viewer; no Dock icon for \(appName)")
            return
        }
        do {
            let dir = DockTileIPC.tilesDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let iconURL = dir.appendingPathComponent("\(bundleID).png")
            try Self.badged(icon).pngData(size: 256)?.write(to: iconURL)

            // The Dock shows the executable's file name, so copy the stub under the app's name.
            let safeName = appName.replacingOccurrences(of: "/", with: "-")
            let binary = dir.appendingPathComponent("\(safeName) (remote)")
            if FileManager.default.fileExists(atPath: binary.path) {
                try FileManager.default.removeItem(at: binary)
            }
            try FileManager.default.copyItem(at: stub, to: binary)

            let process = Process()
            process.executableURL = binary
            process.arguments = ["--bundle-id", bundleID, "--icon", iconURL.path]
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in self?.tiles.removeValue(forKey: bundleID) }
            }
            try process.run()
            tiles[bundleID] = process
        } catch {
            Log.warn("could not start Dock tile for \(appName): \(error)")
        }
    }

    func removeTile(bundleID: String) {
        guard let process = tiles.removeValue(forKey: bundleID) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            DockTileIPC.quit, object: nil, userInfo: [DockTileIPC.bundleIDKey: bundleID], deliverImmediately: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if process.isRunning { process.terminate() }
        }
    }

    func removeAll() {
        DistributedNotificationCenter.default().postNotificationName(DockTileIPC.quitAll, object: nil, userInfo: nil, deliverImmediately: true)
        for process in tiles.values where process.isRunning { process.terminate() }
        tiles.removeAll()
    }

    /// The app icon with a "remote" badge in the bottom-right corner.
    static func badged(_ icon: NSImage) -> NSImage {
        let size: CGFloat = 256
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

            let badge = NSRect(x: size - 104, y: 8, width: 96, height: 96)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -6, dy: -6)).fill()
            NSColor.systemTeal.setFill()
            NSBezierPath(ovalIn: badge).fill()

            let config = NSImage.SymbolConfiguration(pointSize: 54, weight: .bold)
            if let symbol = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            {
                let symbolRect = NSRect(
                    x: badge.midX - symbol.size.width / 2, y: badge.midY - symbol.size.height / 2,
                    width: symbol.size.width, height: symbol.size.height
                )
                symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.white.setFill()
                symbolRect.fill(using: .sourceAtop)
            }
            return true
        }
        return result
    }
}
