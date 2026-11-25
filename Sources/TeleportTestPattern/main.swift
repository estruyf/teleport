import AppKit
import QuartzCore
import TeleportCore

// A window for measuring Teleport's video: run it on the host, share it, open it on the viewer
// with `video.probe` on, and the viewer logs latency and frame rate (docs/video-quality.md).
//
// Every refresh it stamps a frame counter and the time into a block pattern in its top-left
// corner. Keys 1–4 (typed in the portal on the viewer as well) switch what the rest shows:
//   1 idle       nothing moves; the stamp ticks once a second (paint-over, keep-alive)
//   2 text       a page of code scrolling 4 pt a frame (the common case)
//   3 drag       a detailed panel sliding across a busy background (a dragged window)
//   4 animation  every pixel changes every frame (the worst case)

final class PatternView: NSView {
    private(set) var mode: TestPattern.Mode
    private var counter: UInt32 = 0
    private var stamp = TestPattern.Stamp(counter: 0, timeMs: 0, mode: .idle)
    private var frame0 = CACurrentMediaTime()
    private var lastIdleTick = 0.0
    private var drawnPerSecond = 0
    private var shownFPS = 0
    private var fpsSince = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var cardRect = CGRect.zero
    private let lines: [String] = {
        let words = ["let", "var", "func", "return", "guard", "else", "self", "frame", "buffer", "encoder", "portal", "viewer",
                     "latency", "bitrate", "await", "try", "if", "for", "in", "{", "}", "(", ")", "=", "+", "0x3F", "nil", "true"]
        var seed: UInt64 = 7
        return (0 ..< 400).map { line in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let indent = String(repeating: "    ", count: Int(seed >> 60) % 4)
            let count = 3 + Int(seed >> 40) % 12
            let body = (0 ..< count).map { i in words[Int((seed >> UInt64(i * 3 % 50)) % UInt64(words.count))] }.joined(separator: " ")
            return String(format: "%4d  ", line + 1) + indent + body
        }
    }()

    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    init(mode: TestPattern.Mode) {
        self.mode = mode
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        guard window != nil else { return }
        // Follows the refresh of whichever display the window is on: the Stage, on a headless host.
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func keyDown(with event: NSEvent) {
        guard let digit = event.characters.flatMap(Int.init), let next = TestPattern.Mode(rawValue: digit - 1) else {
            return super.keyDown(with: event)
        }
        mode = next
        frame0 = CACurrentMediaTime()
        needsDisplay = true
    }

    /// The stamp in the last drawn frame.
    var drawnStamp: TestPattern.Stamp { stamp }

    /// One frame's worth of change without a display link, for --self-check.
    func advance() {
        lastIdleTick = 0
        tick()
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if now - fpsSince >= 1 {
            shownFPS = drawnPerSecond
            drawnPerSecond = 0
            fpsSince = now
        }
        if mode == .idle {
            // Only the stamp changes, once a second: a still window, as far as motion goes.
            guard now - lastIdleTick >= 1 || lastIdleTick == 0 else { return }
            lastIdleTick = now
        }
        counter &+= 1
        drawnPerSecond += 1
        stamp = TestPattern.Stamp(counter: counter, timeMs: TestPattern.nowMs(), mode: mode)
        switch mode {
        case .idle:
            setNeedsDisplay(patternArea)
        case .drag:
            let old = cardRect
            cardRect = card(at: now - frame0)
            setNeedsDisplay(old.union(cardRect).insetBy(dx: -2, dy: -2))
            setNeedsDisplay(patternArea)
        case .text, .animation:
            needsDisplay = true
        }
    }

    /// The pattern, and the label beside it with the mode and drawn frame rate.
    private var patternArea: CGRect {
        CGRect(x: 0, y: TestPattern.originY - 8, width: bounds.width, height: Double(TestPattern.rows) * TestPattern.block + 16)
    }

    private func card(at t: Double) -> CGRect {
        let size = CGSize(width: min(640, bounds.width * 0.5), height: min(420, bounds.height * 0.5))
        let x = (bounds.width - size.width) * (0.5 + 0.5 * sin(t * 1.3))
        let y = 120 + (bounds.height - 140 - size.height) * (0.5 + 0.5 * sin(t * 0.9))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let t = CACurrentMediaTime() - frame0
        switch mode {
        case .idle:
            NSColor.white.setFill()
            dirtyRect.fill()
            drawText(in: dirtyRect, scroll: 0, top: 120)
        case .text:
            NSColor.white.setFill()
            dirtyRect.fill()
            drawText(in: dirtyRect, scroll: t * 240, top: 120)
        case .drag:
            // A busy, still background, like a desktop full of windows.
            NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
            dirtyRect.fill()
            drawText(in: dirtyRect, scroll: 0, top: 120, color: NSColor(calibratedWhite: 0.55, alpha: 1))
            let card = cardRect
            if card.intersects(dirtyRect) {
                cg.saveGState()
                NSColor.white.setFill()
                card.fill()
                NSColor.systemBlue.setStroke()
                NSBezierPath(rect: card.insetBy(dx: 1, dy: 1)).stroke()
                cg.clip(to: card.insetBy(dx: 8, dy: 8))
                drawText(in: card, scroll: 0, top: card.minY + 8, left: card.minX + 12)
                cg.restoreGState()
            }
        case .animation:
            // Diagonal colour bands sliding every frame: nothing for the encoder to reuse.
            let band = 48.0
            let shift = (t * 300).truncatingRemainder(dividingBy: band * 2)
            var x = -bounds.height - band * 2 + shift
            var index = 0
            while x < bounds.width {
                let hue = (Double(index) * 0.07 + t * 0.2).truncatingRemainder(dividingBy: 1)
                NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                let path = NSBezierPath()
                path.move(to: CGPoint(x: x, y: 0))
                path.line(to: CGPoint(x: x + band, y: 0))
                path.line(to: CGPoint(x: x + band + bounds.height, y: bounds.height))
                path.line(to: CGPoint(x: x + bounds.height, y: bounds.height))
                path.fill()
                x += band
                index += 1
            }
        }
        drawPattern()
    }

    private func drawText(in rect: CGRect, scroll: Double, top: Double, left: Double = 24, color: NSColor = .black) {
        let lineHeight = 18.0
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let first = max(0, Int((rect.minY - top + scroll) / lineHeight))
        let last = Int((rect.maxY - top + scroll) / lineHeight) + 1
        guard last >= first else { return }
        for row in first ... last {
            let y = top + Double(row) * lineHeight - scroll
            guard y >= top - lineHeight else { continue }
            (lines[row % lines.count] as NSString).draw(at: CGPoint(x: left, y: y), withAttributes: attributes)
        }
    }

    private func drawPattern() {
        // A white frame around it, so the blocks read the same on any background.
        let size = CGSize(width: Double(TestPattern.columns) * TestPattern.block, height: Double(TestPattern.rows) * TestPattern.block)
        NSColor.white.setFill()
        CGRect(x: TestPattern.originX - 6, y: TestPattern.originY - 6, width: size.width + 12, height: size.height + 12).fill()
        NSColor.black.setFill()
        for (index, bit) in TestPattern.bits(stamp).enumerated() where bit {
            let center = TestPattern.center(of: index)
            CGRect(x: center.x - TestPattern.block / 2, y: center.y - TestPattern.block / 2, width: TestPattern.block, height: TestPattern.block).fill()
        }
        let label = "\(mode.rawValue + 1) \(mode.name)  \(shownFPS) fps drawn  #\(stamp.counter)   keys 1 idle · 2 text · 3 drag · 4 animation"
        let labelX = TestPattern.originX + size.width + 18
        NSColor.white.setFill()
        CGRect(x: labelX - 4, y: TestPattern.originY - 6, width: bounds.width - labelX, height: size.height + 12).fill()
        (label as NSString).draw(at: CGPoint(x: labelX, y: TestPattern.originY + 10),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.black])
    }
}

let arguments = CommandLine.arguments

/// `--self-check`: draws each mode offscreen at 2x and reads the pattern back the way the
/// viewer's probe does. Checks the drawing and the reading agree, without Teleport or a network.
if arguments.contains("--self-check") {
    let ok = MainActor.assumeIsolated { () -> Bool in
        _ = NSApplication.shared
        var ok = true
        for mode in TestPattern.Mode.allCases {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            let view = PatternView(mode: mode)
            window.contentView = view
            view.advance()
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2560, pixelsHigh: 1600, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            let stamp = TestPattern.read(scale: 2) { x, y in
                UInt8(((rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.greenComponent ?? 0) * 255).rounded())
            }
            let fine = stamp?.mode == mode && stamp?.counter == view.drawnStamp.counter
            ok = ok && fine
            print("\(mode.name): \(stamp.map { "#\($0.counter) \($0.mode.name) at \($0.timeMs)" } ?? "unreadable") \(fine ? "ok" : "MISMATCH")")
        }
        return ok
    }
    print(ok ? "PASS" : "FAIL")
    exit(ok ? 0 : 1)
}
let startMode = arguments.firstIndex(of: "--mode").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    .flatMap { name in TestPattern.Mode.allCases.first { $0.name == name } } ?? .text

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    // The content view covers the title bar too, so the pattern sits at a fixed offset from the
    // window's top-left corner: the corner of the frame Teleport captures.
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.titlebarAppearsTransparent = true
    window.title = "Teleport Test Pattern"
    let view = PatternView(mode: startMode)
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    let menu = NSMenu()
    let item = NSMenuItem()
    item.submenu = NSMenu()
    item.submenu?.addItem(withTitle: "Quit Test Pattern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(item)
    app.mainMenu = menu
    app.activate(ignoringOtherApps: true)
    app.run()
}
