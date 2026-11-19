import Foundation
import Testing
@testable import Stow

struct SponsorBlockTests {
    @Test func buildsRequestURL() throws {
        let components = try #require(URLComponents(url: SponsorBlock.url(videoId: "-tCjS49NmyU"), resolvingAgainstBaseURL: false))
        #expect(components.host == "sponsor.ajay.app")
        #expect(components.path == "/api/skipSegments")
        #expect(components.queryItems?.first { $0.name == "videoID" }?.value == "-tCjS49NmyU")
        #expect(components.queryItems?.first { $0.name == "categories" }?.value
                == #"["sponsor","selfpromo","interaction","intro","outro"]"#)
        #expect(SponsorBlock.url(videoId: "x").absoluteString.contains("%22sponsor%22"))
    }

    @Test func parsesSkipSegmentsSorted() {
        let data = Data("""
        [{"segment":[120.5,180],"UUID":"a","category":"sponsor","videoDuration":600,"actionType":"skip","locked":0},
         {"segment":[0,12],"UUID":"b","category":"intro","actionType":"skip"},
         {"segment":[200,260],"UUID":"c","category":"selfpromo","actionType":"mute"},
         {"segment":[300,300.4],"UUID":"d","category":"interaction","actionType":"skip"},
         {"segment":[400],"UUID":"e","category":"outro","actionType":"skip"},
         {"segment":[500,560],"UUID":"f","category":"outro"}]
        """.utf8)
        #expect(SponsorBlock.parse(data) == [
            SponsorSegment(category: "intro", start: 0, end: 12),
            SponsorSegment(category: "sponsor", start: 120.5, end: 180),
            SponsorSegment(category: "outro", start: 500, end: 560),
        ])
    }

    @Test func malformedResponseMeansNoSegments() {
        #expect(SponsorBlock.parse(Data("Not Found".utf8)).isEmpty)
        #expect(SponsorBlock.parse(Data(#"{"segment":[1,2]}"#.utf8)).isEmpty)
    }

    private let segments = [SponsorSegment(category: "intro", start: 0, end: 10),
                            SponsorSegment(category: "sponsor", start: 60, end: 90)]

    @Test func skipsInsideSegment() {
        #expect(SponsorBlock.segmentToSkip(at: 0, in: segments, skipped: []) == 0)
        #expect(SponsorBlock.segmentToSkip(at: 61.2, in: segments, skipped: []) == 1)
    }

    @Test func doesNotSkipOutsideOrNearEnd() {
        #expect(SponsorBlock.segmentToSkip(at: 30, in: segments, skipped: []) == nil)
        #expect(SponsorBlock.segmentToSkip(at: 59.9, in: segments, skipped: []) == nil)
        #expect(SponsorBlock.segmentToSkip(at: 89.6, in: segments, skipped: []) == nil)
        #expect(SponsorBlock.segmentToSkip(at: 90, in: segments, skipped: []) == nil)
        #expect(SponsorBlock.segmentToSkip(at: 5, in: [], skipped: []) == nil)
    }

    @Test func skipsEachSegmentOnce() {
        #expect(SponsorBlock.segmentToSkip(at: 70, in: segments, skipped: [1]) == nil)
        #expect(SponsorBlock.segmentToSkip(at: 5, in: segments, skipped: [1]) == 0)
    }
}
