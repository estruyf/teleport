import CoreServices
import Foundation
import os
import TeleportCore

/// Notices files that a shared app saves to this Mac's Downloads, so the viewer gets a copy.
///
/// Which app saved a file comes from its quarantine properties, which macOS adds to everything an
/// app downloads: the app's bundle ID and name. A file without the flag, or saved
/// by an app that isn't shared, stays here: a browser's downloads never leave this Mac.
///
/// It lists the folder every two seconds and sends a file once its size has held still for two
/// looks, so a download in progress isn't sent half done. Files that were there before watching
/// started are left alone. The listing runs off the main thread: the first one makes macOS ask for
/// access to Downloads, and that question waits for an answer at this Mac.
final class DownloadsWatcher: @unchecked Sendable {
    enum Access: Equatable {
        case unknown
        /// The first listing hasn't returned: macOS is asking at this Mac.
        case asking
        case granted
        case denied
    }

    /// LiveKit sends byte streams in memory-sized chunks, but a copy this large over the internet is a bad surprise.
    static let maxBytes: Int64 = 500_000_000
    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]

    private let queue = DispatchQueue(label: "teleport.downloads", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// File names already handled or already there.
    private var seen: Set<String> = []
    /// Files still growing, with their last size and how many looks it has held.
    private var pending: [String: (size: Int64, steady: Int)] = [:]
    private var allowedApps: [String] = []
    /// Gets the file and the shared app's bundle ID.
    private let onFile: @MainActor (URL, String) -> Void
    /// Whether Teleport may read Downloads here, for the host's checklist.
    var onAccess: (@MainActor (Access) -> Void)?

    init(onFile: @escaping @MainActor (URL, String) -> Void) {
        self.onFile = onFile
    }

    private func report(_ access: Access) {
        let onAccess = onAccess
        DispatchQueue.main.async { MainActor.assumeIsolated { onAccess?(access) } }
    }

    func update(allowedApps: [String]) {
        queue.async { [self] in self.allowedApps = allowedApps }
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            // A listing that doesn't come back quickly is waiting for someone to answer macOS at this Mac.
            let listed = OSAllocatedUnfairLock(initialState: false)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !listed.withLock({ $0 }) else { return }
                Log.warn("downloads: macOS is asking on this Mac for access to Downloads; answer it (through Screen Sharing on a headless Mac)")
                self.report(.asking)
            }
            let names = list()
            listed.withLock { $0 = true }
            guard let names else {
                Log.warn("downloads: can't read Downloads; allow Teleport under System Settings › Privacy & Security › Files and Folders")
                report(.denied)
                return
            }
            report(.granted)
            seen = Set(names)
            pending = [:]
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            Log.info("downloads: watching for files the shared apps save")
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private var folder: URL { FileNames.downloads }

    private func list() -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    private func tick() {
        guard let names = list() else { return }
        for name in names where !seen.contains(name) {
            let url = folder.appendingPathComponent(name)
            guard !name.hasPrefix("."), !Self.partialExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize.map(Int64.init), size > 0
            else { continue }
            let previous = pending[name]
            let steady = previous?.size == size ? (previous?.steady ?? 0) + 1 : 0
            pending[name] = (size, steady)
            guard steady >= 1 else { continue }
            pending[name] = nil
            seen.insert(name)
            guard let agent = Self.quarantineAgent(url), let app = Self.sharedApp(agent, in: allowedApps) else { continue }
            let agentName = agent.name ?? agent.bundleID ?? "?"
            guard size <= Self.maxBytes else {
                Log.warn("downloads: \(name) from \(agentName) is over \(Self.maxBytes / 1_000_000) MB; not sent")
                continue
            }
            let onFile = onFile
            DispatchQueue.main.async { MainActor.assumeIsolated { onFile(url, app) } }
        }
        // A file that was deleted can come back under the same name later.
        let present = Set(names)
        seen.formIntersection(present)
        pending = pending.filter { present.contains($0.key) }
    }

    /// The app that downloaded the file, from its quarantine properties; nil for a file without them.
    static func quarantineAgent(_ url: URL) -> (bundleID: String?, name: String?)? {
        guard let properties = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties else { return nil }
        let bundleID = properties[kLSQuarantineAgentBundleIdentifierKey as String] as? String
        let name = properties[kLSQuarantineAgentNameKey as String] as? String
        guard bundleID?.isEmpty == false || name?.isEmpty == false else { return nil }
        return (bundleID, name)
    }

    /// The shared app that downloaded it: by bundle ID (or a helper of it), else by name.
    static func sharedApp(_ agent: (bundleID: String?, name: String?), in allowedApps: [String]) -> String? {
        if let bundleID = agent.bundleID, let app = SharedApp.match(bundleID, in: allowedApps) { return app }
        if let name = agent.name { return HostController.sharedApp(named: name, in: allowedApps) }
        return nil
    }
}
