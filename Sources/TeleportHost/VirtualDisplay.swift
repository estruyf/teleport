import CoreGraphics
import CPrivate
import Foundation
import TeleportCore

/// A virtual monitor ("Teleport Stage") so a Mac without a screen still renders
/// windows at Retina density. It lives as long as this object (and the process).
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let widthPoints: Int
    let heightPoints: Int
    let hiDPI: Bool

    var displayID: CGDirectDisplayID { display.displayID }

    init?(widthPoints: Int, heightPoints: Int, hiDPI: Bool) {
        let scale = hiDPI ? 2 : 1
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue(label: "teleport.virtual-display")
        descriptor.name = "Teleport Stage"
        descriptor.maxPixelsWide = UInt32(widthPoints * scale)
        descriptor.maxPixelsHigh = UInt32(heightPoints * scale)
        // Roughly a 24" 16:10 panel, so macOS picks a sensible default density.
        descriptor.sizeInMillimeters = CGSize(width: 518, height: 324)
        descriptor.vendorID = 0x7470
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in Log.warn("virtual display was terminated by the system") }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        // Offer the pixel size and the point size; selectMode() picks the HiDPI one afterwards.
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(widthPoints * scale), height: UInt(heightPoints * scale), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt(widthPoints), height: UInt(heightPoints), refreshRate: 60),
        ]
        guard display.apply(settings) else { return nil }

        self.display = display
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.hiDPI = hiDPI
    }

    /// Switches the display to "looks like widthPoints × heightPoints" at 2x when available.
    func selectMode() {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        let scale = hiDPI ? 2 : 1
        let wanted = modes.first { $0.width == widthPoints && $0.pixelWidth == widthPoints * scale }
        if let mode = wanted {
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
            CGCompleteDisplayConfiguration(config, .permanently)
        }
        if let current = CGDisplayCopyDisplayMode(displayID) {
            Log.info("virtual display \(displayID): \(current.width)x\(current.height) pt, \(current.pixelWidth)x\(current.pixelHeight) px")
        }
    }
}
