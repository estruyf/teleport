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

    @Test func hostInfoFromAnOlderHostHasNoClock() throws {
        let json = #"{"name":"Office","publicKey":"ab","version":"0.2.0","port":7880}"#
        #expect(try JSONDecoder().decode(HostInfo.self, from: Data(json.utf8)).timeMs == nil)
        let now = HostInfo(name: "Office", publicKey: "ab", version: "0.3.0", port: 7880, timeMs: 1_790_000_000_000)
        #expect(try JSONDecoder().decode(HostInfo.self, from: JSONEncoder().encode(now)).timeMs == 1_790_000_000_000)
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

    @Test func configWithoutNotificationsLeavesThemOn() throws {
        let decoded = try JSONDecoder().decode(TeleportConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.notifications == nil)
        #expect(decoded.notificationsEnabled)
    }

    @Test func hostStatusFromAnOlderHostWantsNoMicrophone() throws {
        let status = try HostStatus.fromJSON(#"{"locked":false}"#)
        #expect(status.microphoneWanted == nil)
        #expect(try HostStatus.fromJSON(HostStatus(locked: true, microphoneWanted: true).jsonString()).microphoneWanted == true)
    }

    @Test func configWithoutSoundKeysPlaysSoundButKeepsTheMicrophoneOff() throws {
        let decoded = try JSONDecoder().decode(TeleportConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.audioEnabled)
        #expect(!decoded.microphoneEnabled)
        #expect(decoded.microphoneDevice == nil)
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
