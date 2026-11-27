import Foundation

/// Viewer ⇄ dock-tile stub messages, carried by `DistributedNotificationCenter`
/// so neither side needs an app bundle or URL scheme.
public enum DockTileIPC {
    /// Posted by a tile when the user clicks it. `userInfo[bundleIDKey]` names the remote app.
    public static let activate = Notification.Name("ai.teleport.docktile.activate")
    /// Posted by the viewer when the tile for `userInfo[bundleIDKey]` should exit.
    public static let quit = Notification.Name("ai.teleport.docktile.quit")
    /// Posted by the viewer on exit so every tile goes away with it.
    public static let quitAll = Notification.Name("ai.teleport.docktile.quit-all")
    /// Posted by the viewer when the remote app's badge changes; `userInfo[badgeKey]` is the text, or "" for none.
    public static let badge = Notification.Name("ai.teleport.docktile.badge")
    public static let bundleIDKey = "bundleID"
    public static let badgeKey = "badge"

    public static var tilesDirectory: URL {
        TeleportConfig.directory.appendingPathComponent("dock-tiles", isDirectory: true)
    }
}
