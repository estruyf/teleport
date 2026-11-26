import AppKit
import Combine
import Sparkle
import TeleportCore

/// In-app updates with Sparkle, from the appcast attached to the latest GitHub release.
///
/// A viewer gets Sparkle's usual prompt. A host is usually a Mac nobody sits at, so it downloads
/// updates silently and installs one only while no viewer is connected, then relaunches and goes
/// back to hosting on its own (the mode is in `config.json`).
///
/// Only a release bundle carries `SUFeedURL`; debug builds and `swift run` leave the updater off.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// False for builds without a feed: no menu items, no checks.
    let isAvailable: Bool
    @Published private(set) var canCheckForUpdates = false
    /// Set while an update installs, so quitting skips its questions (the relock offer) and doesn't wait on a person.
    @Published private(set) var isInstalling = false
    /// Host: an update is downloaded and waits for the last viewer to leave.
    @Published private(set) var pendingVersion: String?

    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var mode: TeleportConfig.Mode?
    private var hostIdle = true
    private var started = false
    private var cancellables: Set<AnyCancellable> = []
    /// `TELEPORT_FEED_URL` points the updater at another appcast, to try an update before releasing it.
    fileprivate let feedOverride: String?
    /// Started with `TELEPORT_HOME` (a loopback test). A relaunch would lose that and start on `~/.teleport`.
    fileprivate let loopback: Bool

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        feedOverride = env["TELEPORT_FEED_URL"].flatMap { $0.isEmpty ? nil : $0 }
        loopback = !(env["TELEPORT_HOME"] ?? "").isEmpty
        let feed = feedOverride ?? info["SUFeedURL"] as? String ?? ""
        // A loopback host shares the bundle with the real instance; one updater is enough, unless a test feed asks for it.
        isAvailable = !feed.isEmpty && info["SUPublicEDKey"] != nil && Bundle.main.bundleURL.pathExtension == "app" && (!loopback || feedOverride != nil)
        super.init()
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// Starts the updater for this mode. Called again when the mode changes.
    func configure(for mode: TeleportConfig.Mode) {
        guard let controller else { return }
        self.mode = mode
        let updater = controller.updater
        // The host has no one to answer a prompt: it fetches updates by itself and installs them when idle.
        // A viewer keeps whatever its person chose in Sparkle's prompt.
        if mode == .host { updater.automaticallyDownloadsUpdates = true }
        if !started {
            started = true
            // After the run loop is up: the first launch can be inside AppDelegate's init.
            DispatchQueue.main.async {
                do {
                    try updater.start()
                    Log.info("updater started (\(mode.rawValue)), feed \(updater.feedURL?.absoluteString ?? "-")")
                    // A test feed is checked right away, the way a scheduled check would (silently on a host).
                    if self.feedOverride != nil { updater.checkForUpdatesInBackground() }
                } catch {
                    Log.warn("updater did not start: \(error)")
                }
            }
        }
        installIfIdle()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// The host reports whether a viewer is connected; a waiting update installs as soon as none is.
    func hostIsIdle(_ idle: Bool) {
        hostIdle = idle
        installIfIdle()
    }

    private func installIfIdle() {
        guard mode == .host, hostIdle, let install = installNow else { return }
        installNow = nil
        isInstalling = true
        Log.info("installing update \(pendingVersion ?? "?") now that no viewer is connected")
        install()
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for _: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feedOverride }
    }

    nonisolated func updaterShouldRelaunchApplication(_: SPUUpdater) -> Bool {
        MainActor.assumeIsolated {
            if loopback { Log.info("update installed; not relaunching a TELEPORT_HOME instance") }
            return !loopback
        }
    }

    /// An update is downloaded and would install when Teleport quits. A host never quits on its own,
    /// so it takes the immediate path once idle; a viewer leaves it to Sparkle (install on quit, or the prompt).
    nonisolated func updater(_: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        return MainActor.assumeIsolated {
            guard mode == .host else { return false }
            Log.info("update \(version) downloaded; waiting until no viewer is connected")
            pendingVersion = version
            installNow = immediateInstallHandler
            installIfIdle()
            return true
        }
    }

    nonisolated func updaterWillRelaunchApplication(_: SPUUpdater) {
        MainActor.assumeIsolated { isInstalling = true }
    }

    nonisolated func updater(_: SPUUpdater, didAbortWithError error: Error) {
        let message = "\(error)"
        MainActor.assumeIsolated {
            isInstalling = false
            Log.info("update check ended: \(message)")
        }
    }
}
