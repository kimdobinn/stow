import Foundation
import Testing
@testable import Stow

struct VideoDetailsTests {
    @Test func parsesARegularVideo() throws {
        let json = Data(#"{"id": "-tCjS49NmyU", "duration": 805, "live_status": "not_live", "is_live": false, "availability": "public"}"#.utf8)
        #expect(try YTDLPVideoDetails.parse(json: json, id: "-tCjS49NmyU")
                == VideoDetails(id: "-tCjS49NmyU", duration: 805, liveStatus: .none, isPlayable: true, error: nil))
    }

    @Test func parsesLiveAndUpcoming() throws {
        let live = try YTDLPVideoDetails.parse(json: Data(#"{"id": "x", "is_live": true}"#.utf8), id: "x")
        #expect(live.liveStatus == .live)
        #expect(live.duration == nil)
        let upcoming = try YTDLPVideoDetails.parse(json: Data(#"{"id": "y", "live_status": "is_upcoming"}"#.utf8), id: "y")
        #expect(upcoming.liveStatus == .upcoming)
        #expect(!upcoming.isPlayable)
        let archived = try YTDLPVideoDetails.parse(json: Data(#"{"id": "z", "live_status": "was_live", "duration": 3600.5}"#.utf8), id: "z")
        #expect(archived.liveStatus == .wasLive)
        #expect(archived.duration == 3600.5)
    }

    @Test func rejectsNonVideoOutput() {
        #expect(throws: StowError.self) { try YTDLPVideoDetails.parse(json: Data("null".utf8), id: "x") }
        #expect(throws: StowError.self) { try YTDLPVideoDetails.parse(json: Data("not json".utf8), id: "x") }
    }

    /// Real yt-dlp against YouTube. Run with TEST_RUNNER_STOW_NETWORK_TESTS=1 xcodebuild test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STOW_NETWORK_TESTS"] != nil), .timeLimit(.minutes(3)))
    func realVideos() async {
        let results = await YTDLPVideoDetails().details(for: ["-tCjS49NmyU", "EQ9HTMxIjEU", "-tCjS49NmyU"], cookiesFile: nil)
        #expect(results.count == 2)
        let available = results["-tCjS49NmyU"]
        #expect(available?.isPlayable == true)
        #expect(available?.liveStatus == LiveStatus.none)
        #expect((available?.duration ?? 0) > 60)
        // Members-only without cookies: reported, not thrown.
        let members = results["EQ9HTMxIjEU"]
        #expect(members?.isPlayable == false)
        #expect(members?.error?.contains("members") == true)
    }
}
