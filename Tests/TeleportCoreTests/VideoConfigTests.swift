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

    @Test func defaultsMatchWhatPortalsDidBefore() {
        let tuning = VideoTuning(VideoConfig())
        #expect(tuning.codec == .h264)
        #expect(tuning.degradation == .maintainResolution)
        #expect(tuning.maxBitrateKbps == 25000)
        #expect(tuning.playoutDelayMs == nil)
    }

    @Test func togglesParse() throws {
        let tuning = try decode(video: #"{"codec": "h265", "degradation": "maintainFramerateAndResolution", "maxBitrateKbps": 40000, "playoutDelayMs": 0}"#).videoTuning
        #expect(tuning.codec == .h265)
        #expect(tuning.degradation == .maintainFramerateAndResolution)
        #expect(tuning.maxBitrateKbps == 40000)
        #expect(tuning.playoutDelayMs == 0)
        #expect(tuning.problems.isEmpty)
    }

    @Test func anUnknownCodecFallsBackToH264() throws {
        let tuning = try decode(video: #"{"codec": "av1"}"#).videoTuning
        #expect(tuning.codec == .h264)
        #expect(tuning.problems.count == 1)
    }

    /// The claims of a token, decoded without checking the signature.
    func claims(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        let data = try #require(Data(base64Encoded: payload))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func tokensCarryNoRoomConfigByDefault() throws {
        #expect(try claims(AccessToken.make(config: config, identity: "viewer-1"))["roomConfig"] == nil)
    }

    @Test func playoutDelayGoesIntoEveryTokenUnderItsProtojsonNames() throws {
        var config = config
        config.video = try decode(video: #"{"playoutDelayMs": 40}"#).video
        for identity in ["teleport-host", "viewer-1"] {
            let room = try #require(claims(AccessToken.make(config: config, identity: identity))["roomConfig"] as? [String: Any])
            #expect(room["minPlayoutDelay"] as? Int == 40)
            #expect(room["maxPlayoutDelay"] as? Int == 40)
            #expect(room.count == 2)
        }
        // Admin tokens never create the room for a join, so they stay as they were.
        #expect(try claims(AccessToken.admin(config: config))["roomConfig"] == nil)
    }
}
