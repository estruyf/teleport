#!/usr/bin/env swift
// Renders the Teleport app icon and writes an .icns (plus a 1024px PNG next to it).
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
//
// The motif: a window lifting off through a ring of light, on a violet gradient
// (violet is the "remote" colour throughout the app).

import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let outputURL = URL(fileURLWithPath: outputPath)

func render(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size
        let inset = s * 0.10 // macOS icons leave a margin around the squircle
        let squircle = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: squircle, xRadius: squircle.width * 0.225, yRadius: squircle.width * 0.225)

        // Background gradient
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.47, green: 0.30, blue: 0.93, alpha: 1), // #7a4ded
            NSColor(calibratedRed: 0.26, green: 0.14, blue: 0.62, alpha: 1), // #42249e
        ])!
        gradient.draw(in: path, angle: -70)

        // Soft highlight at the top
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        glow.draw(in: NSRect(x: squircle.minX, y: squircle.midY, width: squircle.width, height: squircle.height / 2), angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // Portal ring: two concentric arcs with a glow
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let center = NSPoint(x: squircle.midX, y: squircle.minY + squircle.height * 0.36)
        for (radius, width, alpha) in [(squircle.width * 0.40, s * 0.030, 0.55), (squircle.width * 0.47, s * 0.018, 0.30)] {
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: radius, startAngle: 10, endAngle: 170)
            ring.lineWidth = width
            ring.lineCapStyle = .round
            NSColor(calibratedRed: 0.85, green: 0.80, blue: 1.0, alpha: alpha).setStroke()
            ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        // The window, tilted up slightly as if lifting off
        let winW = squircle.width * 0.56
        let winH = squircle.height * 0.42
        let winRect = NSRect(x: squircle.midX - winW / 2, y: squircle.minY + squircle.height * 0.20, width: winW, height: winH)
        let transform = NSAffineTransform()
        transform.translateX(by: winRect.midX, yBy: winRect.midY)
        transform.rotate(byDegrees: -6)
        transform.translateX(by: -winRect.midX, yBy: -winRect.midY)

        NSGraphicsContext.saveGraphicsState()
        transform.concat()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.04
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.02)
        shadow.set()

        let corner = winW * 0.09
        let frame = NSBezierPath(roundedRect: winRect, xRadius: corner, yRadius: corner)
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        frame.fill()

        NSShadow().set() // no shadow for the inner parts

        // Title bar
        let barH = winH * 0.20
        let barRect = NSRect(x: winRect.minX, y: winRect.maxY - barH, width: winW, height: barH)
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: barRect.minX, y: barRect.minY))
        bar.line(to: NSPoint(x: barRect.minX, y: barRect.maxY - corner))
        bar.appendArc(withCenter: NSPoint(x: barRect.minX + corner, y: barRect.maxY - corner), radius: corner, startAngle: 180, endAngle: 90, clockwise: true)
        bar.line(to: NSPoint(x: barRect.maxX - corner, y: barRect.maxY))
        bar.appendArc(withCenter: NSPoint(x: barRect.maxX - corner, y: barRect.maxY - corner), radius: corner, startAngle: 90, endAngle: 0, clockwise: true)
        bar.line(to: NSPoint(x: barRect.maxX, y: barRect.minY))
        bar.close()
        NSColor(calibratedRed: 0.90, green: 0.88, blue: 0.98, alpha: 1).setFill()
        bar.fill()

        // Traffic lights
        let dot = barH * 0.42
        for (i, color) in [NSColor(calibratedRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                           NSColor(calibratedRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                           NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.35, alpha: 1)].enumerated() {
            let x = barRect.minX + barH * 0.55 + CGFloat(i) * dot * 1.6
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: barRect.midY - dot / 2, width: dot, height: dot)).fill()
        }

        // Content lines, so it reads as an app window
        NSColor(calibratedRed: 0.70, green: 0.62, blue: 0.95, alpha: 1).setFill()
        let lineH = winH * 0.055
        for (i, w) in [0.62, 0.45, 0.55].enumerated() {
            let y = barRect.minY - winH * 0.22 - CGFloat(i) * lineH * 2.4
            NSBezierPath(roundedRect: NSRect(x: winRect.minX + winW * 0.12, y: y, width: winW * w, height: lineH), xRadius: lineH / 2, yRadius: lineH / 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Beam: three fading chevrons rising from the window
        let chevronW = squircle.width * 0.16
        for (i, alpha) in [0.95, 0.60, 0.30].enumerated() {
            let y = winRect.maxY + squircle.height * (0.10 + CGFloat(i) * 0.085)
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: squircle.midX - chevronW / 2, y: y))
            chevron.line(to: NSPoint(x: squircle.midX, y: y + chevronW * 0.45))
            chevron.line(to: NSPoint(x: squircle.midX + chevronW / 2, y: y))
            chevron.lineWidth = s * 0.028
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.white.withAlphaComponent(alpha).setStroke()
            chevron.stroke()
        }
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = outputURL.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(render(size: CGFloat(pixels)), pixels: pixels).write(to: iconset.appendingPathComponent(name))
    }
}
try png(render(size: 1024), pixels: 1024).write(to: outputURL.deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "wrote \(outputURL.path)" : "iconutil failed")
