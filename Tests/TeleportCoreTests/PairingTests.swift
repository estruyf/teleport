import CryptoKit
import Foundation
@testable import TeleportCore
import Testing

@Suite struct PairingTests {
    @Test func sealedPairingOpensOnlyWithTheSameCode() throws {
        let host = DeviceIdentity(privateKey: .init())
        let viewer = DeviceIdentity(privateKey: .init())
        let code = "123456"

        let viewerKey = try PairingCrypto.key(viewer, theirPublicHex: host.publicKeyHex, salt: code, info: PairingCrypto.pairInfo)
        let box = try PairingCrypto.seal(PairPayload(viewerName: "MacBook", viewerKey: viewer.publicKeyHex), with: viewerKey)

        let hostKey = try PairingCrypto.key(host, theirPublicHex: viewer.publicKeyHex, salt: code, info: PairingCrypto.pairInfo)
        let payload = try PairingCrypto.open(PairPayload.self, box, with: hostKey)
        #expect(payload.viewerName == "MacBook")
        #expect(payload.viewerKey == viewer.publicKeyHex)

        let wrongKey = try PairingCrypto.key(host, theirPublicHex: viewer.publicKeyHex, salt: "654321", info: PairingCrypto.pairInfo)
        #expect(throws: (any Error).self) { try PairingCrypto.open(PairPayload.self, box, with: wrongKey) }
    }

    @Test func fingerprintMatchesOnBothSides() throws {
        let host = DeviceIdentity(privateKey: .init())
        let viewer = DeviceIdentity(privateKey: .init())
        let viewerKey = try PairingCrypto.key(viewer, theirPublicHex: host.publicKeyHex, salt: "000000", info: PairingCrypto.pairInfo)
        let hostKey = try PairingCrypto.key(host, theirPublicHex: viewer.publicKeyHex, salt: "000000", info: PairingCrypto.pairInfo)
        let a = PairingCrypto.fingerprint(viewer.publicKeyHex, host.publicKeyHex, key: viewerKey)
        let b = PairingCrypto.fingerprint(viewer.publicKeyHex, host.publicKeyHex, key: hostKey)
        #expect(a == b)
        #expect(a.count == 7) // "123 456"
    }

    @Test func sessionKeyIgnoresTheCode() throws {
        let host = DeviceIdentity(privateKey: .init())
        let viewer = DeviceIdentity(privateKey: .init())
        let a = try PairingCrypto.key(viewer, theirPublicHex: host.publicKeyHex, salt: "", info: PairingCrypto.sessionInfo)
        let b = try PairingCrypto.key(host, theirPublicHex: viewer.publicKeyHex, salt: "", info: PairingCrypto.sessionInfo)
        #expect(a.withUnsafeBytes { Data($0) } == b.withUnsafeBytes { Data($0) })
        let pairKey = try PairingCrypto.key(viewer, theirPublicHex: host.publicKeyHex, salt: "123456", info: PairingCrypto.pairInfo)
        #expect(a.withUnsafeBytes { Data($0) } != pairKey.withUnsafeBytes { Data($0) })
    }

    @Test func malformedKeyIsRejected() {
        let me = DeviceIdentity(privateKey: .init())
        #expect(throws: (any Error).self) { try PairingCrypto.key(me, theirPublicHex: "zz", salt: "", info: PairingCrypto.sessionInfo) }
        #expect(throws: (any Error).self) { try PairingCrypto.key(me, theirPublicHex: "00", salt: "", info: PairingCrypto.sessionInfo) }
    }

    @Test func pairingCodeIsSixDigits() {
        for _ in 0 ..< 50 {
            let code = PairingCrypto.pairingCode()
            #expect(code.count == 6)
            let allDigits = code.allSatisfy { $0.isNumber }
            #expect(allDigits)
        }
    }

    @Test func hexRoundTrip() {
        let data = Data((0 ..< 32).map { UInt8($0 * 7 % 256) })
        #expect(Data(hex: data.hex) == data)
        #expect(Data(hex: "abc") == nil)
        #expect(Data(hex: "zz") == nil)
    }
}

@Suite struct TokenTests {
    @Test func accessTokenIsASignedHS256JWTForTheRoom() throws {
        let config = TeleportConfig(
            mode: nil, deviceName: "Mac", apiKey: "key1", apiSecret: "secret", room: "teleport", port: 7880,
            allowedApps: [], virtualDisplay: .init(enabled: false, width: 1920, height: 1200, hiDPI: true),
            livekitServerPath: nil, clipboardSync: nil, sounds: nil
        )
        let token = AccessToken.make(config: config, identity: "viewer-abc", ttl: 60)
        let parts = token.split(separator: ".")
        #expect(parts.count == 3)

        func decode(_ part: Substring) throws -> [String: Any] {
            var s = String(part).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while s.count % 4 != 0 { s += "=" }
            return try JSONSerialization.jsonObject(with: Data(base64Encoded: s)!) as! [String: Any]
        }
        let header = try decode(parts[0])
        let claims = try decode(parts[1])
        #expect(header["alg"] as? String == "HS256")
        #expect(claims["iss"] as? String == "key1")
        #expect(claims["sub"] as? String == "viewer-abc")
        #expect((claims["video"] as? [String: Any])?["room"] as? String == "teleport")

        let signingInput = Data((parts[0] + "." + parts[1]).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: signingInput, using: SymmetricKey(data: Data("secret".utf8)))
        let expected = Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(String(parts[2]) == expected)
    }
}

@Suite struct ProtocolTests {
    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

    @Test func rpcReplyWrapsErrorsAndDecodesResults() async throws {
        let failure = await RPCReply.wrap { throw Boom() }
        #expect(throws: (any Error).self) { try RPCReply.decode(WindowInfo.self, from: failure) }
        let window = WindowInfo(id: 7, app: "Ghostty", bundleID: "com.mitchellh.ghostty", title: "zsh", width: 800, height: 600)
        let ok = await RPCReply.wrap { try window.jsonString() }
        let decoded = try RPCReply.decode(WindowInfo.self, from: ok)
        #expect(decoded == window)
    }

    @Test func trackNames() {
        #expect(TrackName.forWindow(42) == "win-42")
        #expect(TrackName.windowID(from: "win-42") == 42)
        #expect(TrackName.windowID(from: "cam") == nil)
    }

    @Test func olderConfigWithoutNewFlagsStillDecodes() throws {
        let json = """
        {"apiKey":"k","apiSecret":"s","room":"r","port":7880,"allowedApps":[],"deviceName":"Mac",
         "virtualDisplay":{"enabled":false,"width":1920,"height":1200,"hiDPI":true}}
        """
        let config = try JSONDecoder().decode(TeleportConfig.self, from: Data(json.utf8))
        #expect(config.mode == nil)
        #expect(config.clipboardSyncEnabled)
        #expect(!config.soundsEnabled)
        #expect(config.controlPort == 7883)
    }
}
