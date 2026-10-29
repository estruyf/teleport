import CryptoKit
import Foundation
import TeleportCore

/// Talks to a host's control endpoint: discover, pair, and fetch session tokens.
enum HostClient {
    /// Pairing waits for the person at the host to press Allow, so this one is patient.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func controlURL(address: String, port: Int) -> URL {
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        return URL(string: "http://\(host):\(port + 3)")!
    }

    static func info(address: String, port: Int) async throws -> HostInfo {
        try await get(controlURL(address: address, port: port).appendingPathComponent(ControlPath.info))
    }

    /// Returns the fingerprint to show while the host decides, then the paired host once it allows.
    static func pair(address: String, port: Int, code: String, identity: DeviceIdentity, name: String,
                     showFingerprint: @MainActor (String) -> Void) async throws -> PairedHost
    {
        let info = try await info(address: address, port: port)
        let key = try PairingCrypto.key(identity, theirPublicHex: info.publicKey, salt: code, info: PairingCrypto.pairInfo)
        await showFingerprint(PairingCrypto.fingerprint(identity.publicKeyHex, info.publicKey, key: key))

        let payload = PairPayload(viewerName: name, viewerKey: identity.publicKeyHex)
        let request = PairRequest(viewerKey: identity.publicKeyHex, box: try PairingCrypto.seal(payload, with: key))
        let response: PairResponse = try await post(controlURL(address: address, port: port).appendingPathComponent(ControlPath.pair), request)
        let result = try PairingCrypto.open(PairResult.self, response.box, with: key)
        return PairedHost(name: result.hostName, address: address, port: port, publicKey: info.publicKey)
    }

    static func token(for host: PairedHost, identity: DeviceIdentity) async throws -> TokenResult {
        let key = try PairingCrypto.key(identity, theirPublicHex: host.publicKey, salt: "", info: PairingCrypto.sessionInfo)
        let payload = TokenPayload(timestamp: Int(Date().timeIntervalSince1970), nonce: TeleportConfig.randomNonce())
        let request = TokenRequest(viewerKey: identity.publicKeyHex, box: try PairingCrypto.seal(payload, with: key))
        let response: TokenResponse = try await post(host.controlURL.appendingPathComponent(ControlPath.token), request)
        return try PairingCrypto.open(TokenResult.self, response.box, with: key)
    }

    // MARK: - HTTP

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        try await perform(URLRequest(url: url))
    }

    private static func post<T: Decodable>(_ url: URL, _ body: some Encodable) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private static func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PairingError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            switch status {
            case 403: throw PairingError.denied
            case 408: throw PairingError.expired
            case 410: throw PairingError.expired
            case 401: throw PairingError.notTrusted
            case 409: throw PairingError.replay
            default:
                let message = (try? JSONDecoder().decode(ControlError.self, from: data))?.error ?? "HTTP \(status)"
                throw PairingError.unreachable(message)
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
