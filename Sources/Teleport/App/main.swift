import AppKit
import SwiftUI
import TeleportCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var window: NSWindow?
    private var statusBar: StatusBar?
    private var quitting = false

    func applicationDidFinishLaunching(_: Notification) {
        statusBar = StatusBar(app: model) { [weak self] in self?.showWindow() }
        // Always open the window on launch, also for a host: a relaunch (after granting
        // Screen Recording, say) must not look like a crash. Closing it keeps the app in the menu bar.
        showWindow()
    }

    func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Teleport"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: RootView(app: model))
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("TeleportMain")
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// Stop services before quitting, off the main thread, so the window shows that instead of a beachball.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRunning else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
        // Logout, restart and shutdown carry a quit reason; those mustn't wait on a dialog.
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
        Task {
            if model.host != nil, !systemQuit { await offerToRelock() }
            // A disconnect that never returns must not keep the app alive; terminate() cleans up what's left.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            await model.shutdown(message: "Stopping services and quitting…")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static let skipRelockOffer = "skipRelockOfferOnQuit"

    /// Keeping the Mac unlocked is a macOS setting that outlives Teleport; offer to undo it on the way out.
    private func offerToRelock() async {
        guard !UserDefaults.standard.bool(forKey: Self.skipRelockOffer) else { return }
        guard await Task.detached(priority: .userInitiated, operation: { !ScreenSharingRelock.isOn() }).value else { return }
        let alert = NSAlert()
        alert.messageText = "Turn off “Stay unlocked after Screen Sharing”?"
        alert.informativeText = "This macOS setting stays on after Teleport quits, so closing Screen Sharing won't lock this Mac again. Leave it on if this Mac will keep hosting."
        alert.addButton(withTitle: "Turn Off…")
        alert.addButton(withTitle: "Leave On")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: Self.skipRelockOffer) }
        guard response == .alertFirstButtonReturn else { return }
        if await Task.detached(priority: .userInitiated, operation: { ScreenSharingRelock.set(true) }).value {
            Log.info("Screen Sharing relocks this Mac again")
        }
    }

    func applicationWillTerminate(_: Notification) {
        model.terminate()
    }
}

Log.setup(role: "app")

// Ctrl-C / kill should take livekit-server down with us; AppKit doesn't handle signals itself.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        Log.info("signal \(sig) received; shutting down")
        MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.model.terminate()
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)

    // Standard menus, so ⌘Q, ⌘W, ⌘C and ⌘V work in the main window; portal windows swallow shortcuts themselves.
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About Teleport", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Teleport", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Teleport", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu

    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenuItem.submenu = windowMenu
    app.windowsMenu = windowMenu
    app.mainMenu = mainMenu

    app.run()
}
