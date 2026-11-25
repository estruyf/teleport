import CryptoKit
import Foundation

/// Mints LiveKit access tokens (HS256 JWTs) from the shared API key and secret.
public enum AccessToken {
    public static func make(config: TeleportConfig, identity: String, ttl: TimeInterval = 24 * 3600) -> String {
        sign(config: config, identity: identity, ttl: ttl, video: [
            "room": config.room,
            "roomJoin": true,
            "canPublish": true,
            "canSubscribe": true,
            "canPublishData": true,
        ], roomConfig: roomConfig(config.videoTuning))
    }

    /// The `roomConfig` claim for `video.playoutDelayMs`. livekit-server reads it only from the token
    /// of the join that creates the room, and that is the host's own, so every token carries it.
    /// The server also ignores it when both delays are 0; LiveKitServer writes the delay into its
    /// config file too, which covers that case. The keys are protojson names: unknown ones are
    /// dropped without an error.
    static func roomConfig(_ tuning: VideoTuning) -> [String: Any]? {
        guard let delay = tuning.playoutDelayMs else { return nil }
        return ["minPlayoutDelay": delay, "maxPlayoutDelay": delay]
    }

    /// For the server's own API (RoomService), e.g. to remove a revoked viewer.
    public static func admin(config: TeleportConfig) -> String {
        sign(config: config, identity: "teleport-admin", ttl: 60, video: ["room": config.room, "roomAdmin": true])
    }

    static func sign(config: TeleportConfig, identity: String, ttl: TimeInterval, video: [String: Any], roomConfig: [String: Any]? = nil) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        var claims: [String: Any] = [
            "iss": config.apiKey,
            "sub": identity,
            "name": identity,
            "nbf": now - 10,
            "exp": now + Int(ttl),
            "video": video,
        ]
        if let roomConfig { claims["roomConfig"] = roomConfig }
        let signingInput = base64URL(try! JSONSerialization.data(withJSONObject: header))
            + "." + base64URL(try! JSONSerialization.data(withJSONObject: claims))
        let key = SymmetricKey(data: Data(config.apiSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        return signingInput + "." + base64URL(Data(signature))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
