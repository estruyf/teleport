import Foundation
@testable import TeleportCore
import Testing

/// Hosts and viewers update one at a time, so new fields must decode from either side's older JSON.
@Suite struct CompatibilityTests {
    /// In memory; loadOrCreate() would write to ~/.teleport.
    let config = TeleportConfig(
        mode: .host, deviceName: "Test", apiKey: "teleport-test", apiSecret: "secret", room: "teleport", port: 7880,
        allowedApps: [], virtualDisplay: .init(enabled: false, width: 1920, height: 1200, hiDPI: true),
        livekitServerPath: nil, clipboardSync: nil, sounds: nil, keepAlive: nil
    )

    @Test func openResponseFromAnOlderHostHasNoScale() throws {
        let json = #"{"trackName":"win-7","window":{"id":7,"app":"Code","bundleID":"com.microsoft.VSCode","title":"","width":800,"height":600}}"#
        let response = try OpenResponse.fromJSON(json)
        #expect(response.scale == nil)
        #expect(try OpenResponse.fromJSON(OpenResponse(trackName: "win-7", window: response.window, scale: 2).jsonString()).scale == 2)
    }

    @Test func iconMessagesStayCompatible() throws {
        // An older viewer sends only the bundle ID, and gets one PNG back.
        #expect(try IconRequest.fromJSON(#"{"bundleID":"a.b"}"#).size == nil)
        #expect(try IconResponse.fromJSON(#"{"png":"AAAA"}"#).parts == nil)
    }

    @Test func configWithoutKeepAliveLeavesItOff() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "keepAlive")
        let decoded = try JSONDecoder().decode(TeleportConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.keepAliveEnabled == false)
    }

    @Test func adminTokenOnlyAdministersTheRoom() throws {
        let token = AccessToken.admin(config: config)
        let parts = token.split(separator: ".")
        #expect(parts.count == 3)
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        let data = try #require(Data(base64Encoded: payload))
        let claims = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let video = try #require(claims["video"] as? [String: Any])
        #expect(video["roomAdmin"] as? Bool == true)
        #expect(video["roomJoin"] == nil)
        #expect(video["room"] as? String == config.room)
    }
}
