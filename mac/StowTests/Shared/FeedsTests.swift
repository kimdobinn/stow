import Foundation
import Testing
@testable import Stow

struct FeedsTests {
    private func video(_ id: String, hoursAgo: Double?) -> Video {
        Video(id: id, channelId: "UC", channelTitle: "C", title: id,
              publishedAt: hoursAgo.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * 3600) },
              thumbnailURL: nil, isMembersOnly: false, liveStatus: .none)
    }

    @Test func subscriptionsMergeTheFeedWithFollowedChannelsNewestFirst() {
        // The feed is newest first; "b" has no date, so it stays right under "a".
        let feed = [video("a", hoursAgo: 1), video("b", hoursAgo: nil), video("c", hoursAgo: 10)]
        let channels = [video("x", hoursAgo: 5), video("a", hoursAgo: 1), video("y", hoursAgo: nil)]
        #expect(Feeds.subscriptions(feed: feed, channelVideos: channels).map(\.id) == ["a", "b", "x", "c", "y"])
    }

    @Test func aFeedEntryBecomesAVideo() {
        let entry = FeedVideo(id: "abcdefghijk", channelId: "UC", channelTitle: "C", title: "T", duration: 600,
                              thumbnailURL: nil, isMembersOnly: true, isLive: false, wasLive: true, timestamp: 1_800_000_000)
        let video = entry.video()
        #expect(video.publishedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(video.liveStatus == .wasLive && video.isMembersOnly && video.duration == 600)
        #expect(video.thumbnailURL?.absoluteString == "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg")
        let known = Date(timeIntervalSince1970: 1_700_000_000)
        var undated = entry
        undated.timestamp = nil
        #expect(undated.video(knownDate: known).publishedAt == known)
    }
}
