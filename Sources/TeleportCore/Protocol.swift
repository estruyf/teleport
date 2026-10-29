import Foundation

/// Messages between host and viewer. Control calls go over LiveKit RPC,
/// input events over the data channel on the `input` topic.
public enum RPCMethod {
    public static let list = "teleport.list"
    public static let open = "teleport.open"
    public static let close = "teleport.close"
    public static let resize = "teleport.resize"
}

public enum Topic {
    public static let input = "input"
}

public enum TrackName {
    public static func forWindow(_ id: UInt32) -> String { "win-\(id)" }

    public static func windowID(from name: String) -> UInt32? {
        guard name.hasPrefix("win-") else { return nil }
        return UInt32(name.dropFirst(4))
    }
}

public struct WindowInfo: Codable, Hashable, Identifiable {
    public var id: UInt32
    public var app: String
    public var bundleID: String
    public var title: String
    /// Size in points.
    public var width: Double
    public var height: Double

    public init(id: UInt32, app: String, bundleID: String, title: String, width: Double, height: Double) {
        self.id = id
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.width = width
        self.height = height
    }
}

public struct OpenRequest: Codable {
    public var windowID: UInt32
    public init(windowID: UInt32) { self.windowID = windowID }
}

public struct OpenResponse: Codable {
    public var trackName: String
    public var window: WindowInfo
    public init(trackName: String, window: WindowInfo) {
        self.trackName = trackName
        self.window = window
    }
}

public struct CloseRequest: Codable {
    public var windowID: UInt32
    public init(windowID: UInt32) { self.windowID = windowID }
}

public struct ResizeRequest: Codable {
    public var windowID: UInt32
    /// Size in points.
    public var width: Double
    public var height: Double
    public init(windowID: UInt32, width: Double, height: Double) {
        self.windowID = windowID
        self.width = width
        self.height = height
    }
}

/// One mouse or keyboard event, in coordinates normalised to the window (0...1, top-left origin).
public struct InputEvent: Codable {
    public enum Kind: String, Codable {
        case mouseMove, mouseDown, mouseUp, mouseDrag, scroll, keyDown, keyUp
    }

    public var kind: Kind
    public var windowID: UInt32
    public var x: Double = 0
    public var y: Double = 0
    /// 0 = left, 1 = right, 2+ = other.
    public var button: Int = 0
    public var clickCount: Int = 1
    public var keyCode: UInt16 = 0
    /// `CGEventFlags` raw value.
    public var flags: UInt64 = 0
    public var scrollX: Double = 0
    public var scrollY: Double = 0

    public init(kind: Kind, windowID: UInt32) {
        self.kind = kind
        self.windowID = windowID
    }
}

public extension Encodable {
    func jsonString() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

public extension Decodable {
    static func fromJSON(_ string: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(string.utf8))
    }
}

/// RPC replies carry either the result or `{"error": "..."}`, since LiveKit only
/// passes built-in error types through intact.
public struct RPCFailure: Codable, Error, CustomStringConvertible {
    public var error: String
    public init(_ error: String) { self.error = error }
    public var description: String { error }
}

public enum RPCReply {
    public static func wrap(_ body: () async throws -> String) async -> String {
        do {
            return try await body()
        } catch {
            return (try? RPCFailure(String(describing: error)).jsonString()) ?? "{\"error\":\"unknown\"}"
        }
    }

    public static func decode<T: Decodable>(_: T.Type, from payload: String) throws -> T {
        if let failure = try? RPCFailure.fromJSON(payload) {
            throw failure
        }
        return try T.fromJSON(payload)
    }
}

// MARK: - Apps

public extension RPCMethod {
    static let apps = "teleport.apps"
    static let launch = "teleport.launch"
    static let icon = "teleport.icon"
}

/// An app the host may share: installed, possibly running, with its current windows.
public struct AppInfo: Codable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    public var running: Bool
    public var windows: [WindowInfo]

    public var id: String { bundleID }

    public init(bundleID: String, name: String, running: Bool, windows: [WindowInfo]) {
        self.bundleID = bundleID
        self.name = name
        self.running = running
        self.windows = windows
    }
}

public struct LaunchRequest: Codable {
    public var bundleID: String
    /// When the app already runs, ask it for a new window (⌘N) instead of just activating it.
    public var newWindow: Bool
    public init(bundleID: String, newWindow: Bool) {
        self.bundleID = bundleID
        self.newWindow = newWindow
    }
}

/// Windows that appeared for the app after the launch; the viewer opens them.
public struct LaunchResponse: Codable {
    public var windows: [WindowInfo]
    public init(windows: [WindowInfo]) { self.windows = windows }
}

public struct IconRequest: Codable {
    public var bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }
}

/// PNG, base64; sized to fit LiveKit's 15 KB RPC reply limit.
public struct IconResponse: Codable {
    public var png: String
    public init(png: String) { self.png = png }
}

// MARK: - Files and control

public extension Topic {
    /// Byte streams carrying dropped files, host-bound.
    static let files = "files"
}

public extension RPCMethod {
    /// Host to viewer: your pairing was revoked, disconnect.
    static let kick = "teleport.kick"
}

/// Attributes on a file stream: where on the window it was dropped.
public enum FileDropKeys {
    public static let windowID = "windowID"
    public static let x = "x"
    public static let y = "y"
}
