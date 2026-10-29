import AppKit
import TeleportCore

/// Watches the pasteboard and reports new text; applies text from the other Mac.
/// Remembers what it applied so the change doesn't bounce back.
@MainActor
final class ClipboardSync {
    /// Data packets are capped at 15 KB; longer clipboard text stays local.
    static let maxBytes = 14_000

    var onChange: ((String) -> Void)?
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var lastText: String?

    func start() {
        guard timer == nil else { return }
        lastCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func apply(_ text: String) {
        guard text != lastText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastText = text
        lastCount = pasteboard.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastCount else { return }
        lastCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), text != lastText, text.utf8.count <= Self.maxBytes else { return }
        lastText = text
        onChange?(text)
    }
}

/// Short sounds for the moments that matter. System sounds, nothing bundled.
enum Sounds {
    nonisolated(unsafe) static var enabled = true

    static func portalOpened() { play("Pop") }
    static func paired() { play("Glass") }
    static func connected() { play("Tink") }

    private static func play(_ name: String) {
        guard enabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
