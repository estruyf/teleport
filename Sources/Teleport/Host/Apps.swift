import AppKit
import TeleportCore

/// The host's view of shareable apps: installed, running, and their windows.
@MainActor
enum AppCatalog {
    static func list(allowedApps: [String]) async throws -> [AppInfo] {
        let windows = try await WindowCatalog.list(allowedApps: allowedApps)
        var byBundle: [String: [WindowInfo]] = [:]
        for window in windows { byBundle[window.bundleID, default: []].append(window) }

        // Only the apps on the allow-list, installed or not, so the viewer can launch them too.
        return allowedApps.compactMap { bundleID in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            guard url != nil || running else { return nil }
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? byBundle[bundleID]?.first?.app ?? bundleID
            return AppInfo(bundleID: bundleID, name: name, running: running, windows: byBundle[bundleID] ?? [])
        }
    }

    /// Launches or activates the app, optionally asking for a new window, and returns the windows that appeared.
    static func launch(_ request: LaunchRequest, allowedApps: [String], injector: InputInjector) async throws -> LaunchResponse {
        guard allowedApps.contains(request.bundleID) else {
            throw HostError("\(request.bundleID) is not in allowedApps")
        }
        // A locked Mac launches the app but swallows ⌘N, and new windows never show.
        guard !ScreenLock.isLocked else {
            throw HostError("the host is locked. Unlock it, then try again.")
        }
        let before = Set(try await WindowCatalog.list(allowedApps: [request.bundleID]).map(\.id))
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: request.bundleID).isEmpty

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: request.bundleID) else {
            throw HostError("\(request.bundleID) is not installed on the host")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        if wasRunning, request.newWindow {
            // ⌘N is the one convention every app on the allow-list follows.
            try await Task.sleep(nanoseconds: 300_000_000)
            app.activate()
            injector.pressShortcut(keyCode: 45, flags: .maskCommand) // kVK_ANSI_N
        }

        // Give the app up to 8 s to show a window; a cold launch of VS Code takes a few.
        for _ in 0 ..< 32 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let now = try await WindowCatalog.list(allowedApps: [request.bundleID])
            let fresh = now.filter { !before.contains($0.id) }
            if !fresh.isEmpty { return LaunchResponse(windows: fresh) }
            if !wasRunning, !now.isEmpty { return LaunchResponse(windows: now) }
        }
        return LaunchResponse(windows: [])
    }

    /// Quits every instance of the app and waits up to 5 s for it to go.
    static func quit(_ request: QuitRequest, allowedApps: [String]) async throws -> QuitResponse {
        guard allowedApps.contains(request.bundleID) else {
            throw HostError("\(request.bundleID) is not in allowedApps")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: request.bundleID)
        for app in running {
            _ = request.force ? app.forceTerminate() : app.terminate()
        }
        for _ in 0 ..< 20 {
            if running.allSatisfy(\.isTerminated) { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let quit = running.allSatisfy(\.isTerminated)
        Log.info("\(request.force ? "force quit" : "quit") \(request.bundleID): \(quit ? "done" : "still running")")
        return QuitResponse(quit: quit)
    }

    /// PNG icon shrunk until it fits a 15 KB RPC reply.
    static func icon(bundleID: String) throws -> IconResponse {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw HostError("\(bundleID) is not installed on the host")
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        for size in [128, 96, 64, 48] {
            guard let png = image.pngData(size: size) else { continue }
            let encoded = png.base64EncodedString()
            if encoded.utf8.count < 14_000 { return IconResponse(png: encoded) }
        }
        throw HostError("icon for \(bundleID) is too large")
    }
}
