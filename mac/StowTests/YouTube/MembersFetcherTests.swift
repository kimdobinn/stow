import Foundation
import Testing
@testable import Stow

struct MembersFetcherTests {
    static let json = """
    {"id": "UUMFeUP5Kb-EDDplwAi0H02XlA", "_type": "playlist", "channel": "TQQQ\\ubbf8\\uce5c\\ub188",
     "channel_id": "UCeUP5Kb-EDDplwAi0H02XlA", "entries": [
      {"id": "EQ9HTMxIjEU", "title": "Why Nobody Gets Rich Off SQQQ", "live_status": null,
       "availability": "subscriber_only", "channel": "TQQQ\\ubbf8\\uce5c\\ub188", "channel_id": "UCeUP5Kb-EDDplwAi0H02XlA",
       "timestamp": null, "_type": "url"},
      null,
      {"id": "upcoming001", "title": "Premiere", "live_status": "is_upcoming", "release_timestamp": 1795100000},
      {"id": "privateVid1", "title": "[Private video]", "availability": "private"},
      {"id": "wasLiveVid1", "title": "Stream replay", "live_status": "was_live", "timestamp": 1795000000}
     ]}
    """

    @Test func parsesEntries() throws {
        let videos = try MembersFetcher.parse(playlistJSON: Data(Self.json.utf8), channelId: "UCeUP5Kb-EDDplwAi0H02XlA")
        #expect(videos.map(\.id) == ["EQ9HTMxIjEU", "upcoming001", "wasLiveVid1"])
        let first = videos[0]
        #expect(first.channelTitle == "TQQQ미친놈")
        #expect(first.isMembersOnly)
        #expect(first.liveStatus == .unknown)
        #expect(first.publishedAt == nil)
        #expect(first.thumbnailURL == URL(string: "https://i.ytimg.com/vi/EQ9HTMxIjEU/hqdefault.jpg"))
        #expect(videos[1].liveStatus == .upcoming)
        #expect(videos[1].channelTitle == "TQQQ미친놈") // playlist-level fallback
        #expect(videos[2].liveStatus == .wasLive)
        #expect(videos[2].publishedAt == Date(timeIntervalSince1970: 1_795_000_000))
    }

    @Test func originalMetadataReplacesTranslatedTitles() throws {
        let translated = try MembersFetcher.parse(playlistJSON: Data(Self.json.utf8), channelId: "UCeUP5Kb-EDDplwAi0H02XlA")
        let published = Date(timeIntervalSince1970: 1_795_100_000)
        let original = Video(id: "EQ9HTMxIjEU", channelId: "UCeUP5Kb-EDDplwAi0H02XlA", channelTitle: "TQQQ미친놈",
                             title: "SQQQ로 부자가 되는 사람들이 없는 이유", publishedAt: published, thumbnailURL: nil,
                             isMembersOnly: false, liveStatus: .unknown)
        let corrected = MembersFetcher.applyOriginalMetadata(translated, from: [original])
        #expect(corrected[0].title == "SQQQ로 부자가 되는 사람들이 없는 이유")
        #expect(corrected[0].publishedAt == published)
        #expect(corrected[0].isMembersOnly)
        #expect(corrected[1] == translated[1])
    }

    @Test func nullOutputIsEmpty() throws {
        #expect(try MembersFetcher.parse(playlistJSON: Data("null".utf8), channelId: "UC").isEmpty)
    }

    @Test func garbageThrowsParse() {
        #expect(throws: StowError.self) { try MembersFetcher.parse(playlistJSON: Data("{oops".utf8), channelId: "UC") }
    }

    @Test func missingCookiesMeansNotSignedIn() async {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString).txt")
        await #expect(throws: StowError.notSignedIn) {
            try await MembersFetcher(ytdlp: YTDLP()).fetch(channelId: "UCeUP5Kb-EDDplwAi0H02XlA", cookiesFile: missing)
        }
    }
}
