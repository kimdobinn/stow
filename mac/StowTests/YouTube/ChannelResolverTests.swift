import Foundation
import Testing
@testable import Stow

struct ChannelResolverTests {
    @Test(arguments: [
        ("UC-XMoeMXbYrMlvmyLSwDd3g", ChannelReference.id("UC-XMoeMXbYrMlvmyLSwDd3g")),
        ("  @JackhopkinsCEO \n", .handle("JackhopkinsCEO")),
        ("TQQQCRAZY", .handle("TQQQCRAZY")),
        ("@한글채널", .handle("한글채널")),
        ("https://www.youtube.com/@JackhopkinsCEO", .handle("JackhopkinsCEO")),
        ("https://www.youtube.com/@TQQQCRAZY/videos", .handle("TQQQCRAZY")),
        ("youtube.com/@TQQQCRAZY", .handle("TQQQCRAZY")),
        ("https://www.youtube.com/@%ED%95%9C%EA%B8%80", .handle("한글")),
        ("https://m.youtube.com/channel/UCeUP5Kb-EDDplwAi0H02XlA/featured", .id("UCeUP5Kb-EDDplwAi0H02XlA")),
        ("https://www.youtube.com/c/SomeName", .url(URL(string: "https://www.youtube.com/c/SomeName")!)),
        ("http://youtube.com/user/PewDiePie", .url(URL(string: "https://www.youtube.com/user/PewDiePie")!)),
        ("https://www.youtube.com/watch?v=-tCjS49NmyU&t=10s", .video("-tCjS49NmyU")),
        ("https://youtu.be/EQ9HTMxIjEU?si=abc", .video("EQ9HTMxIjEU")),
        ("https://www.youtube.com/shorts/EQ9HTMxIjEU", .video("EQ9HTMxIjEU")),
        ("https://www.youtube.com/live/EQ9HTMxIjEU", .video("EQ9HTMxIjEU")),
    ])
    func parsesInput(input: String, expected: ChannelReference) {
        #expect(ChannelResolver.parse(input: input) == expected)
    }

    @Test(arguments: ["", "   ", "two words", "https://vimeo.com/@someone", "https://www.youtube.com/feed/subscriptions",
                      "https://www.youtube.com/channel/notAnId", "https://www.youtube.com/watch?v=short", "a/b"])
    func rejectsInput(input: String) {
        #expect(ChannelResolver.parse(input: input) == nil)
    }

    @Test func invalidInputThrowsWithoutNetwork() async {
        await #expect(throws: StowError.invalidChannelInput("not a channel")) {
            try await ChannelResolver().resolve(input: "not a channel")
        }
    }

    @Test func parsesChannelPage() throws {
        let html = """
        <html><head><meta property="og:title" content="Tom &amp; Jerry&#39;s &#xAC00;">
        <meta property="og:image" content="https://yt3.googleusercontent.com/abc=s900-c-k">
        <meta itemprop="identifier" content="UCeUP5Kb-EDDplwAi0H02XlA">
        </head><script>var ytInitialData = {"externalId":"UCeUP5Kb-EDDplwAi0H02XlA",
        "vanityChannelUrl":"http://www.youtube.com/@%ED%95%9C%EA%B8%80"}</script>
        """
        let info = try #require(ChannelPageParser.parse(html: html))
        #expect(info == ChannelInfo(id: "UCeUP5Kb-EDDplwAi0H02XlA", title: "Tom & Jerry's 가", handle: "@한글",
                                    avatarURL: URL(string: "https://yt3.googleusercontent.com/abc=s900-c-k")))
    }

    @Test func channelPageWithoutIdIsNil() {
        #expect(ChannelPageParser.parse(html: #"<meta property="og:title" content="Before you continue">"#) == nil)
    }

    @Test func findsVideoOwner() {
        let html = #"{"videoDetails":{"videoId":"x","channelId":"UC-XMoeMXbYrMlvmyLSwDd3g"}} "channelId":"UCeUP5Kb-EDDplwAi0H02XlA""#
        #expect(ChannelPageParser.ownerChannelId(watchPage: html) == "UC-XMoeMXbYrMlvmyLSwDd3g")
    }

    @Test func playlistIds() {
        #expect(PlaylistID.longForm(channelId: "UC-XMoeMXbYrMlvmyLSwDd3g") == "UULF-XMoeMXbYrMlvmyLSwDd3g")
        #expect(PlaylistID.membersOnly(channelId: "UCeUP5Kb-EDDplwAi0H02XlA") == "UUMFeUP5Kb-EDDplwAi0H02XlA")
    }
}
