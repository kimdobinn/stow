import Foundation
import Testing
@testable import Stow

struct PastStreamsFetcherTests {
    let tab = """
    {"channel": "Chan", "entries": [
      {"id": "aaaaaaaaaaa", "title": "Translated title", "live_status": "was_live", "duration": 6564.0},
      {"id": "uuuuuuuuuuu", "title": "Soon", "live_status": "is_upcoming"},
      {"id": "lllllllllll", "title": "Now", "live_status": "is_live"},
      {"id": "ppppppppppp", "title": "Just ended", "live_status": "post_live"},
      null,
      {"id": "bbbbbbbbbbb", "title": "Old stream", "live_status": "was_live", "duration": 3600.0}
    ]}
    """

    @Test func keepsFinishedStreamsWithTheFeedsTitlesAndDates() {
        let feed = [Video(id: "aaaaaaaaaaa", channelId: "UCc", channelTitle: "채널", title: "원래 제목",
                          publishedAt: Date(timeIntervalSince1970: 1_800_000_000), thumbnailURL: nil,
                          isMembersOnly: false, liveStatus: .unknown)]
        let streams = PastStreamsFetcher.streams(fromTabJSON: Data(tab.utf8), channelId: "UCc", feed: feed)
        // Only what the feed lists (it has the dates); "Old stream" is past the feed's 15.
        #expect(streams.map(\.id) == ["aaaaaaaaaaa"])
        #expect(streams[0].title == "원래 제목")
        #expect(streams[0].channelTitle == "채널")
        #expect(streams[0].liveStatus == .wasLive)
        #expect(streams[0].duration == 6564)
        #expect(streams[0].publishedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func withoutTheFeedKeepsEveryFinishedStream() {
        let streams = PastStreamsFetcher.streams(fromTabJSON: Data(tab.utf8), channelId: "UCc", feed: nil)
        #expect(streams.map(\.id) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        #expect(streams[1].title == "Old stream")
        #expect(streams[1].channelTitle == "Chan")
        #expect(PastStreamsFetcher.streams(fromTabJSON: Data("<html>".utf8), channelId: "UCc", feed: nil).isEmpty)
    }
}
