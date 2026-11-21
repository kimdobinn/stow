import Foundation
import Testing
@testable import Stow

@MainActor
struct WatchPlayerTests {
    private let video = Video(id: "abc", channelId: "UC1", channelTitle: "Channel", title: "A video",
                              publishedAt: nil, thumbnailURL: nil, isMembersOnly: false, liveStatus: .unknown)

    @Test func watchingToTheEndMarksItWatchedOnce() async throws {
        let fake = FakeAlarmPlayer()
        fake.script.withLock { $0 = [.started(index: 0, videoId: "abc"),
                                     .videoEnded(videoId: "abc", position: 570, duration: 600),
                                     .videoEnded(videoId: "abc", position: 600, duration: 600),
                                     .exited(.finished)] }
        let player = WatchPlayer(player: fake)
        var outcomes: [WatchPlayer.Outcome] = []
        try await player.play(video, cookiesFile: nil) { outcomes.append($0) }
        for _ in 0..<50 where outcomes.isEmpty { await Task.yield() }
        #expect(outcomes == [.watched(videoId: "abc")])
        #expect(fake.plays.withLock { $0.map(\.ids) } == [["abc"]])
        #expect(fake.plays.withLock { $0.first?.output } == .some(nil))
    }

    @Test func stoppingEarlyIsNotWatched() {
        #expect(WatchPlayer.outcome(of: .videoEnded(videoId: "abc", position: 120, duration: 600)) == nil)
        #expect(WatchPlayer.outcome(of: .videoEnded(videoId: "abc", position: 120, duration: nil)) == nil)
        #expect(WatchPlayer.outcome(of: .loadFailed(videoId: "abc", message: "gone"))
                == .failed(videoId: "abc", message: "gone"))
    }
}
