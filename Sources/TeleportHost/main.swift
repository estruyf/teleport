import AppKit
import TeleportCore

@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = HostController()

    func applicationDidFinishLaunching(_: Notification) {
        Task { await controller.start() }
    }

    func applicationWillTerminate(_: Notification) {
        controller.stop()
    }
}

Log.setup(role: "host")

// Ctrl-C / kill should take livekit-server down with us; AppKit doesn't handle signals itself.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        Log.info("signal \(sig) received; shutting down")
        MainActor.assumeIsolated {
            // Stop the child directly; NSApp.terminate may not reach the delegate in time.
            (NSApp.delegate as? HostAppDelegate)?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = HostAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
