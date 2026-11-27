import AppKit
import TeleportCore
import UserNotifications

/// Shows the host's notifications from shared apps as Teleport's own, with the app's icon beside them.
/// Clicking one hands its app and banner to `onOpen`.
@MainActor
final class NotificationPresenter: NSObject {
    var onOpen: ((_ id: String, _ bundleID: String) -> Void)?
    private var askedForPermission = false

    /// `swift run` has no bundle, and the notification center traps without one.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    override init() {
        super.init()
        // Set before launch finishes, so a click that launches Teleport still arrives.
        center?.delegate = self
    }

    func show(_ notification: RemoteNotification, icon: NSImage?) async {
        guard let center, await allowed(center) else { return }
        let content = UNMutableNotificationContent()
        // The banner shows Teleport's icon, so say which app it is from.
        content.title = notification.title.isEmpty ? notification.app : notification.title
        content.subtitle = (notification.title.isEmpty ? [notification.subtitle] : [notification.app, notification.subtitle])
            .filter { !$0.isEmpty }.joined(separator: " · ")
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.bundleID
        content.userInfo = [Keys.id: notification.id, Keys.bundleID: notification.bundleID]
        if let attachment = Self.iconAttachment(icon) { content.attachments = [attachment] }
        let request = UNNotificationRequest(identifier: "\(notification.bundleID).\(notification.id)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            Log.warn("notifications: could not show one from \(notification.bundleID): \(error)")
        }
    }

    /// Asks once; after that the answer lives in System Settings › Notifications › Teleport.
    private func allowed(_ center: UNUserNotificationCenter) async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, !askedForPermission {
            askedForPermission = true
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return status == .authorized || status == .provisional
    }

    /// The attachment's file is moved into the notification store, so each one gets its own copy.
    private static func iconAttachment(_ icon: NSImage?) -> UNNotificationAttachment? {
        guard let png = icon?.pngData(size: 128) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-icon-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: url)
    }

    private enum Keys {
        static let id = "id"
        static let bundleID = "bundleID"
    }
}

extension NotificationPresenter: UNUserNotificationCenterDelegate {
    /// Show it even while Teleport is the active app, which it is whenever a portal has focus.
    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let info = response.notification.request.content.userInfo
        guard let id = info[Keys.id] as? String, let bundleID = info[Keys.bundleID] as? String else { return }
        await MainActor.run { self.onOpen?(id, bundleID) }
    }
}
