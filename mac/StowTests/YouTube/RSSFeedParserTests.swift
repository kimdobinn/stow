import Foundation
import Testing
@testable import Stow

struct RSSFeedParserTests {
    static let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
     <yt:channelId>UCeUP5Kb-EDDplwAi0H02XlA</yt:channelId>
     <title>Videos</title>
     <author><name>TQQQ미친놈</name><uri>https://www.youtube.com/channel/UCeUP5Kb-EDDplwAi0H02XlA</uri></author>
     <entry>
      <id>yt:video:mqmurCuKq24</id>
      <yt:videoId>mqmurCuKq24</yt:videoId>
      <yt:channelId>UCeUP5Kb-EDDplwAi0H02XlA</yt:channelId>
      <title>TQQQ미친놈이 양도세 &amp; 헷지 전략</title>
      <author><name>TQQQ미친놈</name></author>
      <published>2026-11-18T18:00:31+00:00</published>
      <media:group>
       <media:title>ignored</media:title>
       <media:thumbnail url="https://i2.ytimg.com/vi/mqmurCuKq24/hqdefault.jpg" width="480" height="360"/>
      </media:group>
     </entry>
     <entry>
      <yt:videoId>Z23hW9xxQII</yt:videoId>
      <yt:channelId>UCeUP5Kb-EDDplwAi0H02XlA</yt:channelId>
      <title>Second</title>
      <published>2026-11-14T17:02:54Z</published>
     </entry>
    </feed>
    """

    @Test func parsesEntries() throws {
        let videos = try RSSFeedParser.parse(Data(Self.feed.utf8))
        #expect(videos.count == 2)
        let first = try #require(videos.first)
        #expect(first.id == "mqmurCuKq24")
        #expect(first.channelId == "UCeUP5Kb-EDDplwAi0H02XlA")
        #expect(first.channelTitle == "TQQQ미친놈")
        #expect(first.title == "TQQQ미친놈이 양도세 & 헷지 전략")
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_795_024_831))
        #expect(first.thumbnailURL == URL(string: "https://i2.ytimg.com/vi/mqmurCuKq24/hqdefault.jpg"))
        #expect(!first.isMembersOnly && first.liveStatus == .unknown)
        #expect(videos[1].channelTitle == "TQQQ미친놈") // feed-level author fallback
        #expect(videos[1].thumbnailURL == nil)
        #expect(videos[1].publishedAt != nil)
    }

    @Test func emptyFeedHasNoVideos() throws {
        let xml = #"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Videos</title></feed>"#
        #expect(try RSSFeedParser.parse(Data(xml.utf8)).isEmpty)
    }

    @Test(arguments: ["<html><body>Error 404</body></html>", "not xml at all"])
    func rejectsNonFeeds(body: String) {
        #expect(throws: StowError.self) { try RSSFeedParser.parse(Data(body.utf8)) }
    }
}
