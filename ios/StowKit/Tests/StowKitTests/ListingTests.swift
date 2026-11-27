import Foundation
import Testing
@testable import StowKit

/// Ported from the Android app's YouTubeListingTest, YouTubeFeedsTest, FeedsTest,
/// DownloadQualityTest and CommentsTest.
@Suite struct YouTubeListingTests {
    /// Trimmed from yt-dlp's `ytsearch:` answer with `--flat-playlist -J`.
    private let json = """
        {"_type":"playlist","entries":[
          {"_type":"url","ie_key":"Youtube","id":"rFZHOHl-L8A","url":"https://www.youtube.com/watch?v=rFZHOHl-L8A",
           "title":"lofi hip hop radio","channel":"Lofi Girl","channel_id":"UCSJ4gkVC6NrvII8umztf0Ow","duration":null,"live_status":"is_live"},
          {"_type":"url","ie_key":"Youtube","id":"n61ULEU7CO0","url":"https://www.youtube.com/watch?v=n61ULEU7CO0",
           "title":"Best of lofi hip hop 2021","channel":"Lofi Girl","channel_id":"UCSJ4gkVC6NrvII8umztf0Ow","duration":22258.0,
           "live_status":null,"timestamp":null,
           "thumbnails":[{"url":"https://i.ytimg.com/vi/n61ULEU7CO0/small.jpg","width":360},{"url":"https://i.ytimg.com/vi/n61ULEU7CO0/big.jpg","width":720}]},
          {"_type":"url","ie_key":"Youtube","id":"abcdefghijk","url":"https://www.youtube.com/shorts/abcdefghijk","title":"A Short","duration":null},
          {"_type":"url","ie_key":"Youtube","id":"zyxwvutsrqp","url":"https://www.youtube.com/watch?v=zyxwvutsrqp","title":"Short too","duration":45},
          {"_type":"url","ie_key":"Youtube","id":"Upcoming123","url":"https://www.youtube.com/watch?v=Upcoming123","title":"Soon","live_status":"is_upcoming"},
          {"_type":"url","ie_key":"Youtube","id":"WasLive1234","url":"https://www.youtube.com/watch?v=WasLive1234","title":"Last night's stream",
           "uploader":"Someone","duration":7200,"live_status":"was_live"}
        ]}
        """

    @Test func keepsVideosAndFinishedStreamsOnly() throws {
        let videos = try YouTubeListing.parse(json)
        #expect(videos.map(\.id) == ["n61ULEU7CO0", "WasLive1234"])
        let first = videos[0]
        #expect(first.title == "Best of lofi hip hop 2021")
        #expect(first.channelTitle == "Lofi Girl")
        #expect(first.channelId == "UCSJ4gkVC6NrvII8umztf0Ow")
        #expect(first.durationSeconds == 22258)
        #expect(first.thumbnailURL == "https://i.ytimg.com/vi/n61ULEU7CO0/big.jpg")
        #expect(first.liveStatus == nil)
        #expect(first.publishedAt == nil)
        #expect(videos[1].channelTitle == "Someone")
        #expect(videos[1].isPastStream)
        #expect(videos[1].thumbnailURL == "https://i.ytimg.com/vi/WasLive1234/hqdefault.jpg")
    }

    @Test func emptyAnswer() throws {
        #expect(try YouTubeListing.parse(#"{"entries":[]}"#).isEmpty)
        #expect(try YouTubeListing.parse(#"{"_type":"playlist"}"#).isEmpty)
        #expect(throws: (any Error).self) { try YouTubeListing.parse("ERROR: not json") }
    }

    /// Trimmed from yt-dlp's answer for a channel's /videos tab: the videos don't name their channel.
    @Test func channelTabVideosGetTheChannel() throws {
        let json = """
            {"_type":"playlist","channel":"Chillhop Music","channel_id":"UCOxqgCwgOqC2lMqC5PYz_Dg","uploader":"Chillhop Music",
             "thumbnails":[{"url":"https://yt3.example/banner","id":"banner_uncropped"},{"url":"https://yt3.example/avatar","id":"avatar_uncropped"}],
             "entries":[{"_type":"url","ie_key":"Youtube","id":"AodSJJ-ZvuI","url":"https://www.youtube.com/watch?v=AodSJJ-ZvuI",
                         "title":"Chillhop Sanctuary","duration":7249,"live_status":null,"channel_url":"https://www.youtube.com/channel/UCOxqgCwgOqC2lMqC5PYz_Dg"}]}
            """
        let video = try #require(try YouTubeListing.parse(json).first)
        #expect(video.channelId == "UCOxqgCwgOqC2lMqC5PYz_Dg")
        #expect(video.channelTitle == "Chillhop Music")
        #expect(YouTubeListing.channelAvatar(json) == "https://yt3.example/avatar")
        #expect(YouTubeListing.channelTitle(json) == "Chillhop Music")
    }

    @Test func membersOnlyAndDatesAndPostLive() throws {
        let json = """
            {"channel_id":"not-a-UC-id","channel":"Ignored","entries":[
              {"id":"members0001","title":"For members","availability":"subscriber_only","timestamp":1800000000,"duration":600},
              {"id":"postlive001","title":"Processing","live_status":"post_live"},
              {"id":"tooshort","title":"Bad id"},
              {"id":"noTitle0001","title":null,"channel":"null","uploader":"Up"}
            ]}
            """
        let videos = try YouTubeListing.parse(json)
        #expect(videos.map(\.id) == ["members0001", "noTitle0001"])
        #expect(videos[0].isMembersOnly)
        #expect(videos[0].publishedAt == Date(timeIntervalSince1970: 1_800_000_000))
        // The page isn't a channel tab, so it lends no channel.
        #expect(videos[0].channelId == "" && videos[0].channelTitle == "")
        #expect(videos[1].title == "noTitle0001")
        #expect(videos[1].channelTitle == "Up")
    }
}

@Suite struct YouTubeFeedsTests {
    /// The Mac's AccountFeeds JSON (Swift's JSONEncoder leaves out nil fields).
    @Test func parsesTheMacsJSON() throws {
        let json = """
            {"recommended":[
              {"channelId":"UCa","channelTitle":"Chan A","duration":754.0,"id":"aaaaaaaaaaa","isLive":false,
               "isMembersOnly":false,"thumbnailURL":"https:\\/\\/i.ytimg.com\\/vi\\/aaaaaaaaaaa\\/big.jpg","title":"First","wasLive":false},
              {"channelId":"UCb","channelTitle":"Chan B","id":"bbbbbbbbbbb","isLive":false,"isMembersOnly":true,"title":"Stream",
               "wasLive":true,"timestamp":1800000000},
              {"channelId":"UCl","channelTitle":"Chan L","id":"lllllllllll","isLive":true,"isMembersOnly":false,"title":"Live now"},
              {"channelId":"UCs","channelTitle":"Chan S","id":"sssssssssss","duration":40,"isLive":false,"isMembersOnly":false,"title":"Short"}
            ],"subscriptions":[]}
            """
        let feeds = try YouTubeFeeds.parse(json)
        // Nothing live now, no Shorts.
        #expect(feeds.recommended.map(\.id) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        let first = feeds.recommended[0]
        #expect(first.channelTitle == "Chan A")
        #expect(first.durationSeconds == 754)
        #expect(first.thumbnailURL == "https://i.ytimg.com/vi/aaaaaaaaaaa/big.jpg")
        #expect(first.liveStatus == nil)
        #expect(first.publishedAt == nil)
        let stream = feeds.recommended[1]
        #expect(stream.durationSeconds == nil)
        #expect(stream.thumbnailURL == nil)
        #expect(stream.isPastStream)
        #expect(stream.isMembersOnly)
        #expect(stream.publishedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(feeds.subscriptions.isEmpty)
        #expect(feeds.channelAvatars.isEmpty)
    }

    @Test func readsTheChannelPictures() throws {
        let json = #"{"recommended":[],"subscriptions":[],"channelAvatars":{"UCa":"https:\/\/yt3.googleusercontent.com\/a=s176","UCb":""}}"#
        #expect(try YouTubeFeeds.parse(json).channelAvatars == ["UCa": "https://yt3.googleusercontent.com/a=s176"])
    }

    @Test func durationFallsBackToTheFeed() {
        let video = Video(id: "aaaaaaaaaaa", channelId: "UCa", channelTitle: "A", title: "T", publishedAt: nil, thumbnailURL: nil,
                          isMembersOnly: false, durationSeconds: 90)
        #expect(VideoItem(video: video, sent: nil, local: nil, watchedOnMac: false).durationMs == 90_000)
        let local = LocalVideo(id: "aaaaaaaaaaa", state: .downloaded, durationMs: 91_500)
        #expect(VideoItem(video: video, sent: nil, local: local, watchedOnMac: false).durationMs == 91_500)
    }
}

@Suite struct FeedsTests {
    private func item(_ id: String, channel: String = "UCa", minutesAgo: Int? = nil, live: String? = nil, seconds: Int? = nil) -> VideoItem {
        VideoItem(video: Video(id: id, channelId: channel, channelTitle: channel, title: id,
                               publishedAt: minutesAgo.map { Date(timeIntervalSince1970: 1_800_000_000 - Double($0) * 60) },
                               thumbnailURL: nil, isMembersOnly: false, liveStatus: live, durationSeconds: seconds),
                  sent: nil, local: nil, watchedOnMac: false)
    }

    @Test func subscriptionsKeepYouTubesOrderAndSlotInTheMacsByDate() {
        // YouTube's feed: f1 (known to be 10 min old), f2 (undated), f3 (known: 100 min).
        let feed = [item("f1", minutesAgo: 10), item("f2"), item("f3", minutesAgo: 100)]
        let mac = [item("m1", minutesAgo: 5), item("m2", minutesAgo: 50), item("f1", minutesAgo: 10), item("m3", minutesAgo: 500)]
        #expect(Feeds.subscriptions(feed: feed, channelVideos: mac).map(\.id) == ["m1", "f1", "f2", "m2", "f3", "m3"])
        // An empty YouTube feed is just the Mac's, newest first.
        #expect(Feeds.subscriptions(feed: [], channelVideos: mac).map(\.id) == ["m1", "f1", "m2", "m3"])
    }

    @Test func aGroupIsItsChannelsNewestFirst() {
        let group = ChannelGroup(id: "g", name: "Investing", channels: [GroupChannel(id: "UCa", title: "A"), GroupChannel(id: "UCb", title: "B")])
        let all = [item("a1", channel: "UCa", minutesAgo: 30), item("c1", channel: "UCc", minutesAgo: 1),
                   item("b1", channel: "UCb", minutesAgo: 10), item("a2", channel: "UCa")]
        #expect(Feeds.group(group, all: all).map(\.id) == ["b1", "a1", "a2"])
    }

    @Test func pastStreamsGoUnderLive() {
        let (uploads, streams) = Feeds.split([item("v1"), item("s1", live: "wasLive"), item("s2", live: "was_live")])
        #expect(uploads.map(\.id) == ["v1"])
        #expect(streams.map(\.id) == ["s1", "s2"])
    }

    @Test func shortsAreAnythingAMinuteOrLess() {
        #expect(item("s", seconds: 59).video.isShort)
        #expect(item("s", seconds: 60).video.isShort)
        #expect(!item("v", seconds: 61).video.isShort)
        #expect(!item("v").video.isShort)
        #expect(!item("v", seconds: 0).video.isShort)
    }

    @Test func downloadSortsAndFilters() {
        var a = item("a", channel: "Beta", minutesAgo: 10, seconds: 100)
        var b = item("b", channel: "alpha", minutesAgo: 5, seconds: 300)
        let c = item("c", channel: "alpha", seconds: 200)
        a.local = LocalVideo(id: "a", state: .downloaded, downloadedAt: Date(timeIntervalSince1970: 2))
        b.local = LocalVideo(id: "b", state: .downloaded, downloadedAt: Date(timeIntervalSince1970: 1))
        b.watchedOnMac = true
        let all = [a, b, c]
        #expect(Feeds.sorted(all, by: .newest).map(\.id) == ["b", "a", "c"])
        #expect(Feeds.sorted(all, by: .oldest).map(\.id) == ["a", "b", "c"])
        #expect(Feeds.sorted(all, by: .channel).map(\.id) == ["b", "c", "a"])
        #expect(Feeds.sorted(all, by: .longest).map(\.id) == ["b", "c", "a"])
        #expect(Feeds.sorted(all, by: .shortest).map(\.id) == ["a", "c", "b"])
        #expect(Feeds.sorted(all, by: .title).map(\.id) == ["a", "b", "c"])
        #expect(Feeds.sorted([b, a], by: .recentlyDownloaded).map(\.id) == ["a", "b"])
        #expect(Feeds.filtered(all, by: .watched).map(\.id) == ["b"])
        #expect(Feeds.filtered(all, by: .unwatched).map(\.id) == ["a", "c"])
    }

    @Test func sizeEstimate() {
        // An hour at ~3 Mbit/s is about 1.35 GB.
        #expect(Feeds.estimatedBytes(durationMs: 3_600_000) == 1_350_000_000)
    }
}

@Suite struct DownloadQualityTests {
    @Test func capsTheResolutionAndPrefersHardwareCodecs() {
        #expect(DownloadQuality.p1080.formatSort == "res:1080,fps,vcodec:h264,acodec:m4a")
        #expect(DownloadQuality.p720.formatSort == "res:720,fps,vcodec:h264,acodec:m4a")
    }

    @Test func bestHasNoCap() {
        #expect(DownloadQuality.best.formatSort == "res,fps,vcodec:h264,acodec:m4a")
    }

    @Test func theIPhoneOffersUpTo1080p() {
        #expect(DownloadQuality.available == [.p1080, .p720, .p480])
        #expect(DownloadQuality.best.supported == .p1080)
        #expect(DownloadQuality.p1440.supported == .p1080)
        #expect(DownloadQuality.p480.supported == .p480)
    }
}

@Suite struct CommentsTests {
    private let json = """
        {"id":"v","formats":[{"url":"x"}],"comment_count":1234,"comments":[
          {"id":"a","parent":"root","text":"First!","author":"@ann","like_count":1500,"timestamp":1800000000,
           "is_pinned":true,"author_is_uploader":true,"is_favorited":true,"author_thumbnail":"https://yt3.ggpht.com/a.jpg"},
          {"id":"b","parent":"root","text":"Second","author":"@bob"},
          {"id":"a.1","parent":"a","text":"reply one","author":"@cat","like_count":3},
          {"id":"a.2","parent":"a","text":"reply two","author":"@dan"},
          {"id":"x.1","parent":"missing","text":"orphan","author":"@eve"},
          {"id":"c","parent":"root","author":"@no-text"}
        ]}
        """

    @Test func threadsGatherTheirRepliesInOrder() throws {
        let page = try Comments.parse(json)
        #expect(page.totalCount == 1234)
        #expect(page.shownCount == 1234)
        // yt-dlp's count when it's only the number fetched.
        #expect(try Comments.parse(json.replacingOccurrences(of: "1234", with: "6")).shownCount == nil)
        #expect(page.threads.map(\.id) == ["a", "b"])
        let first = page.threads[0]
        #expect(first.replies.map(\.id) == ["a.1", "a.2"])
        #expect(first.likes == 1500)
        #expect(first.isPinned && first.byUploader && first.isHearted)
        #expect(first.postedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(first.authorThumbnail == "https://yt3.ggpht.com/a.jpg")
        let second = page.threads[1]
        #expect(second.likes == 0)
        #expect(second.postedAt == nil)
        #expect(second.authorThumbnail == nil)
        #expect(!second.isPinned)
    }

    @Test func theSavedCopyKeepsOnlyTheComments() throws {
        let trimmed = try Comments.trim(json)
        #expect(!trimmed.contains("formats"))
        #expect(try Comments.parse(json) == Comments.parse(trimmed))
        let none = try Comments.parse(try Comments.trim(#"{"id":"v"}"#))
        #expect(none.threads.isEmpty)
        #expect(none.totalCount == nil)
    }

    @Test func countsReadLikeYouTubes() {
        #expect(Format.shortCount(950) == "950")
        #expect(Format.shortCount(1_000) == "1K")
        #expect(Format.shortCount(1_250) == "1.2K")
        #expect(Format.shortCount(34_900) == "34K")
        #expect(Format.shortCount(1_560_000) == "1.5M")
        #expect(Format.shortCount(23_000_000) == "23M")
    }

    @Test func lengthsAndSizes() {
        #expect(Format.duration(ms: 3_723_000) == "1:02:03")
        #expect(Format.duration(ms: 245_000) == "4:05")
        #expect(Format.minutes(seconds: 30) == "<1 min")
        #expect(Format.minutes(seconds: 3_900) == "1 h 5 min")
        #expect(Format.bytes(1_610_612_736) == "1.5 GB")
        #expect(Format.bytes(5_242_880) == "5 MB")
        #expect(Format.count(1, "video") == "1 video")
        #expect(Format.count(3, "video") == "3 videos")
    }
}
