import Foundation
import ServiceManagement
import TeleportCore

/// Start Teleport at login (a host Mac should come back hosting after a reboot).
enum LoginItem {
    /// An XPC round trip to the system; call it off the main thread.
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("login item \(enabled ? "on" : "off")")
            return nil
        } catch {
            Log.warn("login item change failed: \(error)")
            return "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
