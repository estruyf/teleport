import CryptoKit
import Foundation

/// This Mac's device key. Pairing exchanges public keys; the private key never leaves `~/.teleport/device.key`.
public struct DeviceIdentity {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

    public var publicKeyHex: String { privateKey.publicKey.rawRepresentation.hex }

    /// Short id for display, derived from the public key.
    public var shortID: String { String(SHA256.hash(data: privateKey.publicKey.rawRepresentation).hex.prefix(8)) }

    public static var fileURL: URL { TeleportConfig.directory.appendingPathComponent("device.key") }

    public static func loadOrCreate() throws -> DeviceIdentity {
        if let data = try? Data(contentsOf: fileURL), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return DeviceIdentity(privateKey: key)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try FileManager.default.createDirectory(at: TeleportConfig.directory, withIntermediateDirectories: true)
        try key.rawRepresentation.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return DeviceIdentity(privateKey: key)
    }
}

/// The pairing and session crypto: X25519 agreement, HKDF, ChaCha20-Poly1305.
///
/// Pairing: both sides derive a key from the agreement *and* the one-time code, so a
/// request only opens on a host whose code the viewer typed. Sessions: the agreement alone,
/// which proves the viewer still holds the key the host trusts.
public enum PairingCrypto {
    public static let pairInfo = "teleport/pair/v1"
    public static let sessionInfo = "teleport/session/v1"

    public static func key(_ me: DeviceIdentity, theirPublicHex: String, salt: String, info: String) throws -> SymmetricKey {
        guard let raw = Data(hex: theirPublicHex),
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        else { throw PairingError.badKey }
        let shared = try me.privateKey.sharedSecretFromKeyAgreement(with: theirs)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(salt.utf8), sharedInfo: Data(info.utf8), outputByteCount: 32)
    }

    public static func seal<T: Encodable>(_ value: T, with key: SymmetricKey) throws -> String {
        let box = try ChaChaPoly.seal(try JSONEncoder().encode(value), using: key)
        return box.combined.base64EncodedString()
    }

    public static func open<T: Decodable>(_: T.Type, _ boxed: String, with key: SymmetricKey) throws -> T {
        guard let data = Data(base64Encoded: boxed) else { throw PairingError.badBox }
        let box = try ChaChaPoly.SealedBox(combined: data)
        guard let plain = try? ChaChaPoly.open(box, using: key) else { throw PairingError.badBox }
        return try JSONDecoder().decode(T.self, from: plain)
    }

    /// Six digits both sides can compare; someone in the middle would produce other digits.
    public static func fingerprint(_ keyA: String, _ keyB: String, key: SymmetricKey) -> String {
        let material = key.withUnsafeBytes { Data($0) } + Data((keyA + keyB).utf8)
        let digest = SHA256.hash(data: material)
        let number = digest.withUnsafeBytes { $0.load(as: UInt32.self) } % 1_000_000
        let digits = String(format: "%06u", number)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    public static func pairingCode() -> String {
        String(format: "%06u", UInt32.random(in: 0 ..< 1_000_000))
    }
}

public enum PairingError: Error, CustomStringConvertible {
    case badKey, badBox, wrongCode, expired, denied, notTrusted, replay, unreachable(String)

    public var description: String {
        switch self {
        case .badKey: "The other side sent a malformed key."
        case .badBox: "The message could not be decrypted. Check the pairing code."
        case .wrongCode: "Wrong pairing code."
        case .expired: "The pairing code expired. Ask the host for a new one."
        case .denied: "The host denied the pairing."
        case .notTrusted: "This Mac is not paired with that host. Pair again."
        case .replay: "The request was rejected as a replay."
        case let .unreachable(detail): "Could not reach the host: \(detail)"
        }
    }
}

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

public extension SHA256Digest {
    var hex: String { Data(self).hex }
}
