import Foundation
import Testing
@testable import Stow

struct AccountFeedClientTests {
    @Test func keepsLongFormVideosInOrder() throws {
        let json = """
        {"entries": [
          {"id": "aaaaaaaaaaa", "url": "https://www.youtube.com/watch?v=aaaaaaaaaaa", "title": "First",
           "channel": "Chan A", "channel_id": "UCa", "duration": 754.0,
           "thumbnails": [{"url": "https://i.ytimg.com/vi/aaaaaaaaaaa/small.jpg", "width": 360},
                          {"url": "https://i.ytimg.com/vi/aaaaaaaaaaa/big.jpg", "width": 720}]},
          {"id": "RDmixmixmixmi", "url": "https://www.youtube.com/watch?v=x&list=RDmix", "title": "Mix"},
          {"id": "sssssssssss", "url": "https://www.youtube.com/shorts/sssssssssss", "title": "Short", "channel_id": "UCs"},
          {"id": "uuuuuuuuuuu", "url": "https://www.youtube.com/watch?v=uuuuuuuuuuu", "title": "Soon",
           "channel_id": "UCu", "live_status": "is_upcoming"},
          null,
          {"id": "bbbbbbbbbbb", "url": "https://www.youtube.com/watch?v=bbbbbbbbbbb", "title": "Members",
           "uploader": "Chan B", "channel_id": "UCb", "availability": "subscriber_only", "live_status": "is_live"},
          {"id": "aaaaaaaaaaa", "url": "https://www.youtube.com/watch?v=aaaaaaaaaaa", "title": "First again", "channel_id": "UCa"}
        ]}
        """
        let videos = try AccountFeedClient.parse(feedJSON: Data(json.utf8))
        #expect(videos.map(\.id) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        #expect(videos[0] == FeedVideo(id: "aaaaaaaaaaa", channelId: "UCa", channelTitle: "Chan A", title: "First",
                                       duration: 754, thumbnailURL: URL(string: "https://i.ytimg.com/vi/aaaaaaaaaaa/big.jpg"),
                                       isMembersOnly: false, isLive: false))
        #expect(videos[1].channelTitle == "Chan B")
        #expect(videos[1].isMembersOnly && videos[1].isLive)
        #expect(videos[1].thumbnailURL == URL(string: "https://i.ytimg.com/vi/bbbbbbbbbbb/hqdefault.jpg"))
    }

    @Test func emptyOrBrokenFeeds() throws {
        #expect(try AccountFeedClient.parse(feedJSON: Data("null".utf8)).isEmpty)
        #expect(try AccountFeedClient.parse(feedJSON: Data("{}".utf8)).isEmpty)
        #expect(throws: StowError.self) { try AccountFeedClient.parse(feedJSON: Data("<html>".utf8)) }
    }
}
