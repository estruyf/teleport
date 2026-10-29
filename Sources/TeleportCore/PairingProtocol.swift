import Foundation

/// The host's control endpoint (HTTP on `port + 3`): pairing and session tokens.
/// LiveKit credentials never leave the host; viewers get short-lived tokens here.
public enum ControlPath {
    public static let info = "/info"
    public static let pair = "/pair"
    public static let token = "/token"
}

public struct HostInfo: Codable {
    public var name: String
    public var publicKey: String
    public var version: String
    public var port: Int
    public init(name: String, publicKey: String, version: String, port: Int) {
        self.name = name
        self.publicKey = publicKey
        self.version = version
        self.port = port
    }
}

/// `box` seals a `PairPayload` with the pairing key (agreement + code).
public struct PairRequest: Codable {
    public var viewerKey: String
    public var box: String
    public init(viewerKey: String, box: String) {
        self.viewerKey = viewerKey
        self.box = box
    }
}

public struct PairPayload: Codable {
    public var viewerName: String
    public var viewerKey: String
    public init(viewerName: String, viewerKey: String) {
        self.viewerName = viewerName
        self.viewerKey = viewerKey
    }
}

public struct PairResponse: Codable {
    public var box: String
    public init(box: String) { self.box = box }
}

public struct PairResult: Codable {
    public var hostName: String
    public init(hostName: String) { self.hostName = hostName }
}

/// `box` seals a `TokenPayload` with the session key (agreement only).
public struct TokenRequest: Codable {
    public var viewerKey: String
    public var box: String
    public init(viewerKey: String, box: String) {
        self.viewerKey = viewerKey
        self.box = box
    }
}

public struct TokenPayload: Codable {
    public var timestamp: Int
    public var nonce: String
    public init(timestamp: Int, nonce: String) {
        self.timestamp = timestamp
        self.nonce = nonce
    }
}

public struct TokenResponse: Codable {
    public var box: String
    public init(box: String) { self.box = box }
}

public struct TokenResult: Codable {
    public var token: String
    public var url: String
    public var room: String
    public var hostIdentity: String
    public init(token: String, url: String, room: String, hostIdentity: String) {
        self.token = token
        self.url = url
        self.room = room
        self.hostIdentity = hostIdentity
    }
}

public struct ControlError: Codable, Error, CustomStringConvertible {
    public var error: String
    public init(_ error: String) { self.error = error }
    public var description: String { error }
}

// MARK: - Stores

/// A viewer the host trusts (`~/.teleport/trust.json`).
public struct TrustedDevice: Codable, Identifiable, Hashable {
    public var name: String
    public var publicKey: String
    public var pairedAt: Date
    public var lastSeen: Date?
    public var id: String { publicKey }
    public init(name: String, publicKey: String, pairedAt: Date = Date(), lastSeen: Date? = nil) {
        self.name = name
        self.publicKey = publicKey
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }
}

/// A host the viewer paired with (`~/.teleport/hosts.json`).
public struct PairedHost: Codable, Identifiable, Hashable {
    public var name: String
    public var address: String
    public var port: Int
    public var publicKey: String
    public var pairedAt: Date
    public var id: String { publicKey }
    public init(name: String, address: String, port: Int, publicKey: String, pairedAt: Date = Date()) {
        self.name = name
        self.address = address
        self.port = port
        self.publicKey = publicKey
        self.pairedAt = pairedAt
    }

    public var controlURL: URL { URL(string: "http://\(hostPart):\(port + 3)")! }
    public var signalURL: String { "ws://\(hostPart):\(port)" }
    /// Bracketed when it looks like an IPv6 literal.
    var hostPart: String { address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address }
}

/// A JSON array file in `~/.teleport`.
public struct JSONListStore<Item: Codable> {
    public let url: URL
    public init(filename: String) { url = TeleportConfig.directory.appendingPathComponent(filename) }

    public func load() -> [Item] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Item].self, from: data)) ?? []
    }

    public func save(_ items: [Item]) throws {
        try FileManager.default.createDirectory(at: TeleportConfig.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
