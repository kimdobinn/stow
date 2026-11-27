import Foundation
import Testing
@testable import StowKit

@Suite struct FirestoreValueTests {
    private func documents(_ name: String) throws -> [FirestoreDocument] {
        let object = try JSONSerialization.jsonObject(with: Data(try fixture(name).utf8)) as? [String: Any]
        return (object?["documents"] as? [Any] ?? []).compactMap(FirestoreDocument.init(json:))
    }

    @Test func decodesEveryKind() {
        let json: [String: Any] = ["mapValue": ["fields": [
            "s": ["stringValue": "hi"],
            "b": ["booleanValue": true],
            "i": ["integerValue": "9007199254740993"],
            "d": ["doubleValue": 2.5],
            "n": ["nullValue": NSNull()],
            "t": ["timestampValue": "2026-11-27T09:00:00.123456Z"],
            "a": ["arrayValue": ["values": [["integerValue": "1"], ["stringValue": "x"]]]],
            "empty": ["arrayValue": [String: Any]()],
            "ref": ["referenceValue": "projects/x/databases/(default)/documents/a/b"],
        ]]]
        let value = FirestoreValue(json: json)
        let map = try! #require(value.map)
        #expect(map["s"] == .string("hi"))
        #expect(map["b"]?.bool == true)
        #expect(map["i"] == .int(9_007_199_254_740_993))
        #expect(map["d"]?.double == 2.5)
        #expect(map["d"]?.int == 2)
        #expect(map["n"]?.isNull == true)
        #expect(map["a"] == .array([.int(1), .string("x")]))
        #expect(map["empty"] == .array([]))
        #expect(map["ref"] == .null)
        let date = try! #require(map["t"]?.date)
        #expect(abs(date.timeIntervalSince1970 - 1_795_770_000.123456) < 0.000_01)
    }

    @Test func encodesBackToTheSameJSON() throws {
        let value = FirestoreValue.map([
            "s": "text", "b": true, "i": 42, "d": .double(0.5), "n": nil,
            "t": .timestamp("2026-11-27T09:00:00.123456Z"),
            "a": .array([.string("x"), .map(["k": .bool(false)])]),
        ])
        let data = try JSONSerialization.data(withJSONObject: value.json)
        #expect(FirestoreValue(json: try JSONSerialization.jsonObject(with: data)) == value)
        let object = value.json["mapValue"] as? [String: Any]
        let fields = object?["fields"] as? [String: Any]
        // int64 goes as a string, as Firestore wants.
        #expect((fields?["i"] as? [String: Any])?["integerValue"] as? String == "42")
    }

    @Test func timestampsWithAnyPrecision() {
        #expect(FirestoreTime.date(from: "2026-11-27T09:00:00Z")?.timeIntervalSince1970 == 1_795_770_000)
        #expect(FirestoreTime.date(from: "2026-11-27T09:00:00.5Z")?.timeIntervalSince1970 == 1_795_770_000.5)
        let nanos = FirestoreTime.date(from: "2026-11-27T09:00:00.987654321Z")!.timeIntervalSince1970
        #expect(abs(nanos - 1_795_770_000.987654321) < 0.000_001)
        #expect(FirestoreTime.date(from: "not a date") == nil)
        let now = Date(timeIntervalSince1970: 1_795_770_000.25)
        #expect(FirestoreTime.date(from: FirestoreTime.string(from: now)) == now)
    }

    @Test func sentVideosFromAListAnswer() throws {
        let docs = try documents("videos-list.json")
        #expect(docs.map(\.id) == ["dQw4w9WgXcQ", "lYBUbBu4W08", "brokenDoc01"])
        let sent = docs.compactMap(Remote.sentVideo)
        // A document without a title isn't a video.
        #expect(sent.map(\.video.id) == ["dQw4w9WgXcQ", "lYBUbBu4W08"])
        let rick = sent[0]
        #expect(rick.video.title == "Rick Astley - Never Gonna Give You Up (Official Video)")
        #expect(rick.video.channelId == "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(rick.video.durationSeconds == 213)
        #expect(rick.video.liveStatus == "none")
        #expect(rick.video.thumbnailURL == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        #expect(rick.sentBy == "morning")
        #expect(rick.watched)
        #expect(rick.sentAt == FirestoreTime.date(from: "2026-11-20T07:00:01.5Z"))
        #expect(rick.video.publishedAt != nil)
        let stream = sent[1]
        #expect(stream.video.isPastStream)
        #expect(stream.video.isMembersOnly)
        #expect(stream.video.durationSeconds == 5400)
        #expect(stream.video.publishedAt == nil)
        #expect(stream.video.thumbnailURL == nil)
        #expect(!stream.watched)
    }

    @Test func channelsWithTheirRecentVideos() throws {
        let channels = try documents("channels-list.json").map(Remote.channel).sorted { $0.order < $1.order }
        #expect(channels.map(\.title) == ["jawed", "Rick Astley"])
        let jawed = channels[0]
        #expect(jawed.handle == nil && jawed.avatarURL == nil && jawed.recent.isEmpty)
        let rick = channels[1]
        #expect(rick.handle == "@RickAstleyYT")
        #expect(rick.avatarURL == "https://yt3.googleusercontent.com/rick=s176")
        #expect(rick.recent.map(\.video.id) == ["dQw4w9WgXcQ", "AC3Ejf7vPEY"])
        #expect(rick.recent[0].watched && !rick.recent[1].watched)
        #expect(rick.recent[0].video.channelId == rick.id)
        #expect(rick.recent[0].video.channelTitle == "Rick Astley")
        #expect(rick.recent[0].video.durationSeconds == nil)
        #expect(rick.recent[1].video.durationSeconds == 271)
        #expect(rick.recent[1].video.isMembersOnly)
        #expect(rick.recent[1].video.thumbnailURL == nil)
    }

    @Test func sharedGroupsAndRefreshTimes() throws {
        let document = try #require(FirestoreDocument(json: try JSONSerialization.jsonObject(with: Data(try fixture("shared-phone.json").utf8))))
        #expect(document.path == "shared/phone")
        let shared = Remote.shared(document)
        #expect(shared.groups.map(\.id) == ["g1", "g2"])
        #expect(shared.groups[0].name == "Music")
        #expect(shared.groups[0].channels == [GroupChannel(id: "UCuAXFkgsw1L7xaCfnd5JJOw", title: "Rick Astley"),
                                              GroupChannel(id: "UCnotitle", title: "UCnotitle")])
        #expect(shared.groups[1].name == "Group")
        #expect(shared.refreshHandledAt == shared.refreshRequestedAt)
        #expect(shared.refreshRequestedAt == FirestoreTime.date(from: "2026-11-27T09:00:00.123Z"))
    }

    @Test func groupsEncodeAsTheMacReadsThem() {
        let value = Remote.groupsValue([ChannelGroup(id: "g", name: "News", channels: [GroupChannel(id: "UCa", title: "A")])])
        #expect(value == .array([.map(["id": "g", "name": "News", "channels": .array([.map(["id": "UCa", "title": "A"])])])]))
    }

    @Test func fieldPathsNeedingQuotes() {
        #expect(FirestoreClient.fieldPath("watchedAt") == "watchedAt")
        #expect(FirestoreClient.fieldPath("_x1") == "_x1")
        #expect(FirestoreClient.fieldPath("1st") == "`1st`")
        #expect(FirestoreClient.fieldPath("a-b") == "`a-b`")
        #expect(FirestoreClient.fieldPath("a`b") == "`a\\`b`")
    }
}
