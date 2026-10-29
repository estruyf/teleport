import Foundation
import ServiceManagement
import TeleportCore

/// Start Teleport at login (a host Mac should come back hosting after a reboot).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS wants the user to confirm in System Settings > General > Login Items.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

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
