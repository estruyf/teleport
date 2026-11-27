import AppKit
import CryptoKit
import LiveKit
import TeleportCore

/// Watches the pasteboard and reports new text or a new image; applies them from the other Mac.
/// Remembers what it applied so the change doesn't bounce back.
@MainActor
final class ClipboardSync {
    enum Content {
        case text(String)
        /// PNG.
        case image(Data)
    }

    /// Data packets are capped at 15 KB; longer clipboard text stays local.
    static let maxBytes = 14_000
    /// Images go as byte streams; a screenshot is a few MB, a photo a few more.
    static let maxImageBytes = 25_000_000

    var onChange: ((Content) -> Void)?
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var lastText: String?
    private var lastImage: SHA256.Digest?

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

    /// Puts a PNG on the pasteboard, with a TIFF beside it for apps that only read that.
    func apply(image png: Data) {
        let digest = SHA256.hash(data: png)
        guard digest != lastImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        lastImage = digest
        lastCount = pasteboard.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastCount else { return }
        lastCount = pasteboard.changeCount
        // Text wins: rich text from Office or a browser often carries a picture of itself too.
        if let text = pasteboard.string(forType: .string) {
            guard text != lastText, text.utf8.count <= Self.maxBytes else { return }
            lastText = text
            onChange?(.text(text))
        } else if let png = Self.image(on: pasteboard), png.count <= Self.maxImageBytes {
            let digest = SHA256.hash(data: png)
            guard digest != lastImage else { return }
            lastImage = digest
            onChange?(.image(png))
        }
    }

    /// The pasteboard's image as PNG, unless it holds files: a copied file comes with its icon as a TIFF.
    private static func image(on pasteboard: NSPasteboard) -> Data? {
        let types = pasteboard.types ?? []
        guard !types.contains(.fileURL) else { return nil }
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}

extension ClipboardSync {
    /// Sends `content` to the other Mac: text as a data packet, an image as a byte stream.
    static func send(_ content: Content, over room: Room) {
        switch content {
        case let .text(text):
            // Escaping can make the JSON longer than the text; packets over the limit are dropped.
            guard let data = try? JSONEncoder().encode(ClipboardMessage(text: text)), data.count <= maxBytes else { return }
            Task { try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: Topic.clipboard, reliable: true)) }
        case let .image(png):
            Task {
                do {
                    let options = StreamByteOptions(topic: Topic.clipboardImage, mimeType: "image/png", name: "clipboard.png", compress: false)
                    _ = try await room.localParticipant.sendBytes(png, options: options)
                    Log.info("clipboard: sent an image (\(png.count / 1024) KB)")
                } catch {
                    Log.warn("clipboard: could not send an image: \(error)")
                }
            }
        }
    }

    /// An image from the other Mac, onto this one's pasteboard.
    func receiveImage(_ reader: ByteStreamReader) async {
        if let size = reader.info.totalLength, size > Self.maxImageBytes { return }
        do {
            let png = try await reader.readAll()
            guard png.count <= Self.maxImageBytes, NSBitmapImageRep(data: png) != nil else { return }
            apply(image: png)
            Log.info("clipboard: received an image (\(png.count / 1024) KB)")
        } catch {
            Log.warn("clipboard: image not received: \(error)")
        }
    }
}

/// Short sounds for the moments that matter. System sounds, nothing bundled.
enum Sounds {
    nonisolated(unsafe) static var enabled = false

    static func portalOpened() { play("Pop") }
    static func paired() { play("Glass") }
    static func connected() { play("Tink") }

    private static func play(_ name: String) {
        guard enabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
