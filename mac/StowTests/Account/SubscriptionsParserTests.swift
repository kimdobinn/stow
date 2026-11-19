import Foundation
import Testing
@testable import Stow

struct SubscriptionsParserTests {
    /// Trimmed ytInitialData of /feed/channels (2025-2026 layout): handle in subscriberCountText,
    /// subscriber count in videoCountText, protocol-relative avatars, continuation at the end.
    static let initialData = #"""
    {"responseContext":{"serviceTrackingParams":[]},
     "contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"selected":true,"content":{"sectionListRenderer":{"contents":[
      {"itemSectionRenderer":{"contents":[{"shelfRenderer":{"title":{"runs":[{"text":"All subscriptions"}]},"content":{"expandedShelfContentsRenderer":{"items":[
        {"channelRenderer":{"channelId":"UC-XMoeMXbYrMlvmyLSwDd3g",
          "title":{"simpleText":"Jack Hopkins"},
          "navigationEndpoint":{"browseEndpoint":{"browseId":"UC-XMoeMXbYrMlvmyLSwDd3g","canonicalBaseUrl":"/@JackhopkinsCEO"}},
          "thumbnail":{"thumbnails":[{"url":"//yt3.googleusercontent.com/jack=s88-c-k","width":88,"height":88},{"url":"//yt3.googleusercontent.com/jack=s176-c-k","width":176,"height":176}]},
          "subscriberCountText":{"simpleText":"@JackhopkinsCEO"},"videoCountText":{"simpleText":"1.2M subscribers"}}},
        {"channelRenderer":{"channelId":"UCeUP5Kb-EDDplwAi0H02XlA",
          "title":{"runs":[{"text":"TQQQ "},{"text":"크레이지"}]},
          "navigationEndpoint":{"browseEndpoint":{"browseId":"UCeUP5Kb-EDDplwAi0H02XlA","canonicalBaseUrl":"/@%ED%81%AC%EB%A0%88%EC%9D%B4%EC%A7%80"}},
          "thumbnail":{"thumbnails":[{"url":"https://yt3.ggpht.com/tqqq=s176","width":176,"height":176}]},
          "subscriberCountText":{"simpleText":"@TQQQCRAZY"}}},
        {"channelRenderer":{"channelId":"UCxxxxxxxxxxxxxxxxxxxxx1",
          "title":{"simpleText":"No Handle Channel"},
          "navigationEndpoint":{"browseEndpoint":{"browseId":"UCxxxxxxxxxxxxxxxxxxxxx1","canonicalBaseUrl":"/channel/UCxxxxxxxxxxxxxxxxxxxxx1"}},
          "subscriberCountText":{"simpleText":"3.4K subscribers"}}},
        {"channelRenderer":{"channelId":"UC-XMoeMXbYrMlvmyLSwDd3g","title":{"simpleText":"Duplicate"}}},
        {"channelRenderer":{"title":{"simpleText":"Missing id"}}}
      ]}}}}]}},
      {"continuationItemRenderer":{"trigger":"CONTINUATION_TRIGGER_ON_ITEM_SHOWN","continuationEndpoint":{"clickTrackingParams":"x","commandMetadata":{"webCommandMetadata":{"apiUrl":"/youtubei/v1/browse"}},"continuationCommand":{"token":"4qmFsgKlARIK","request":"CONTINUATION_REQUEST_TYPE_BROWSE"}}}}
     ]}}}}]}}}
    """#

    /// A browse continuation response: the last page, so it has no further continuation.
    static let continuationResponse = #"""
    {"responseContext":{},"onResponseReceivedActions":[{"appendContinuationItemsAction":{"targetId":"browse-feedFEchannels","continuationItems":[
      {"itemSectionRenderer":{"contents":[{"shelfRenderer":{"content":{"expandedShelfContentsRenderer":{"items":[
        {"channelRenderer":{"channelId":"UCzzzzzzzzzzzzzzzzzzzzz2","title":{"simpleText":"Last Page"},
          "navigationEndpoint":{"browseEndpoint":{"canonicalBaseUrl":"/@lastpage"}}}}
      ]}}}}]}}
    ]}}]}
    """#

    @Test func parsesInitialPage() throws {
        let (channels, continuation) = try SubscriptionsParser.parse(Data(Self.initialData.utf8))
        #expect(channels.map(\.id) == ["UC-XMoeMXbYrMlvmyLSwDd3g", "UCeUP5Kb-EDDplwAi0H02XlA", "UCxxxxxxxxxxxxxxxxxxxxx1"])
        #expect(continuation == "4qmFsgKlARIK")

        #expect(channels[0] == ChannelInfo(
            id: "UC-XMoeMXbYrMlvmyLSwDd3g",
            title: "Jack Hopkins",
            handle: "@JackhopkinsCEO",
            avatarURL: URL(string: "https://yt3.googleusercontent.com/jack=s176-c-k")
        ))
        #expect(channels[1].title == "TQQQ 크레이지")
        #expect(channels[1].handle == "@크레이지")
        #expect(channels[1].avatarURL == URL(string: "https://yt3.ggpht.com/tqqq=s176"))
        #expect(channels[2].handle == nil)
        #expect(channels[2].avatarURL == nil)
    }

    @Test func parsesContinuationResponse() throws {
        let (channels, continuation) = try SubscriptionsParser.parse(Data(Self.continuationResponse.utf8))
        #expect(channels.map(\.title) == ["Last Page"])
        #expect(channels.first?.handle == "@lastpage")
        #expect(continuation == nil)
    }

    @Test func legacyContinuationData() throws {
        let json = #"{"continuations":[{"nextContinuationData":{"continuation":"legacy-token"}}]}"#
        #expect(try SubscriptionsParser.parse(Data(json.utf8)).continuation == "legacy-token")
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: StowError.self) { try SubscriptionsParser.parse(Data("<html>".utf8)) }
    }
}
