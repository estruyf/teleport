import CryptoKit
import Foundation

/// Mints LiveKit access tokens (HS256 JWTs) from the shared API key and secret.
public enum AccessToken {
    public static func make(config: TeleportConfig, identity: String, ttl: TimeInterval = 24 * 3600) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": config.apiKey,
            "sub": identity,
            "name": identity,
            "nbf": now - 10,
            "exp": now + Int(ttl),
            "video": [
                "room": config.room,
                "roomJoin": true,
                "canPublish": true,
                "canSubscribe": true,
                "canPublishData": true,
            ],
        ]
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
