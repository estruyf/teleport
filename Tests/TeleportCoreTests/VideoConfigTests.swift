import Foundation
@testable import TeleportCore
import Testing

/// The `video` section is edited by hand; a mistake in it must never cost the config (and the pairing keys).
@Suite struct VideoConfigTests {
    let config = TeleportConfig(
        mode: .host, deviceName: "Test", apiKey: "teleport-test", apiSecret: "secret", room: "teleport", port: 7880,
        allowedApps: [], virtualDisplay: .init(enabled: false, width: 1920, height: 1200, hiDPI: true),
        livekitServerPath: nil, clipboardSync: nil, sounds: nil, keepAlive: nil
    )

    /// The config with `video` set to this JSON object, decoded.
    func decode(video: String) throws -> TeleportConfig {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object["video"] = try JSONSerialization.jsonObject(with: Data(video.utf8))
        return try JSONDecoder().decode(TeleportConfig.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func noVideoSectionKeepsTodaysBehaviour() throws {
        let decoded = try JSONDecoder().decode(TeleportConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.video == nil)
        #expect(decoded.videoTuning.stats == false)
        #expect(decoded.videoTuning.problems.isEmpty)
    }

    @Test func statsTurnsOn() throws {
        #expect(try decode(video: #"{"stats": true}"#).videoTuning.stats)
    }

    @Test func aBadValueIsDroppedNotFatal() throws {
        let decoded = try decode(video: #"{"stats": "yes please"}"#)
        #expect(decoded.apiSecret == "secret")
        #expect(decoded.videoTuning.stats == false)
        #expect(decoded.videoTuning.problems.count == 1)
    }

    @Test func anUnknownKeyIsReported() throws {
        let problems = try decode(video: #"{"Stats": true}"#).videoTuning.problems
        #expect(problems == ["video.Stats is not a setting Teleport knows"])
    }

    @Test func savingKeepsTheSectionAndOmitsUnsetKeys() throws {
        let decoded = try decode(video: #"{"stats": true}"#)
        let json = try #require(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
        #expect(json.contains(#""video":{"stats":true}"#))
    }
}
