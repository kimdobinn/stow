import Foundation
import Testing
@testable import Stow

struct MPVPlaybackTrackerTests {
    private let playlist = [PlayableVideo(video: video("a"), duration: 600),
                            PlayableVideo(video: video("b"), duration: nil),
                            PlayableVideo(video: video("c"), duration: 300)]

    private func emitted(_ effects: [MPVPlaybackTracker.Effect]) -> [PlayerEvent] {
        effects.compactMap { if case .emit(let event) = $0 { event } else { nil } }
    }

    @Test func startsOnFirstPlaybackRestartOnly() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        #expect(tracker.handle(.startFile(entryId: 1)).isEmpty)
        #expect(tracker.handle(.propertyChange(name: "time-pos", value: 0)).isEmpty)
        #expect(tracker.handle(.playbackRestart) == [.emit(.started(index: 0, videoId: "a"))])
        #expect(tracker.handle(.playbackRestart).isEmpty)
        #expect(tracker.startedCount == 1)
    }

    @Test func nowPlayingFollowsLoadingPlaybackAndPause() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        #expect(tracker.nowPlaying == NowPlaying(index: 0, count: 3, video: video("a"), isLoading: true, isPaused: false,
                                                 position: 0, duration: 600, upNext: video("b")))
        _ = tracker.handle(.startFile(entryId: 1))
        _ = tracker.handle(.propertyChange(name: "duration", value: 605))
        _ = tracker.handle(.playbackRestart)
        _ = tracker.handle(.propertyChange(name: "time-pos", value: 42.7))
        _ = tracker.handle(.flagChange(name: "pause", value: true))
        #expect(tracker.nowPlaying == NowPlaying(index: 0, count: 3, video: video("a"), isLoading: false, isPaused: true,
                                                 position: 42, duration: 605, upNext: video("b")))

        // Between entries the next one shows as loading; the last has nothing up next.
        _ = tracker.handle(.endFile(entryId: 1, reason: .eof, error: nil))
        #expect(tracker.nowPlaying.index == 1 && tracker.nowPlaying.isLoading && tracker.nowPlaying.duration == nil)
        _ = tracker.handle(.startFile(entryId: 3))
        _ = tracker.handle(.playbackRestart)
        #expect(tracker.nowPlaying.index == 2 && !tracker.nowPlaying.isLoading && tracker.nowPlaying.upNext == nil)
    }

    @Test func endReportsFurthestPositionAndDuration() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        _ = tracker.handle(.startFile(entryId: 1))
        _ = tracker.handle(.propertyChange(name: "duration", value: 805))
        _ = tracker.handle(.playbackRestart)
        _ = tracker.handle(.propertyChange(name: "time-pos", value: 500))
        _ = tracker.handle(.propertyChange(name: "time-pos", value: 100))
        #expect(emitted(tracker.handle(.endFile(entryId: 1, reason: .eof, error: nil)))
                == [.videoEnded(videoId: "a", position: 500, duration: 805)])
        #expect(tracker.currentIndex == nil)
    }

    @Test func fallsBackToPlaylistDuration() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        _ = tracker.handle(.startFile(entryId: 3))
        _ = tracker.handle(.playbackRestart)
        _ = tracker.handle(.propertyChange(name: "time-pos", value: 12))
        #expect(emitted(tracker.handle(.endFile(entryId: 3, reason: .stop, error: nil)))
                == [.videoEnded(videoId: "c", position: 12, duration: 300)])
    }

    @Test func loadFailureUsesFirstYtdlError() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        _ = tracker.handle(.startFile(entryId: 2))
        _ = tracker.handle(.logMessage(level: "error", prefix: "ytdl_hook", text: "ERROR: [youtube] b: This video is unavailable"))
        _ = tracker.handle(.logMessage(level: "error", prefix: "ytdl_hook", text: "youtube-dl failed: unexpected error occurred"))
        #expect(emitted(tracker.handle(.endFile(entryId: 2, reason: .error, error: "unrecognized file format")))
                == [.loadFailed(videoId: "b", message: "[youtube] b: This video is unavailable")])
        #expect(tracker.exit(stopRequested: false, exitCode: 2) == .failed("[youtube] b: This video is unavailable"))
    }

    @Test func loadFailureWithoutLogUsesFileError() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        _ = tracker.handle(.startFile(entryId: 1))
        #expect(emitted(tracker.handle(.endFile(entryId: 1, reason: .error, error: "loading failed")))
                == [.loadFailed(videoId: "a", message: "loading failed")])
    }

    @Test func skippedBeforeLoadingReportsNothing() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        _ = tracker.handle(.startFile(entryId: 1))
        #expect(tracker.handle(.endFile(entryId: 1, reason: .stop, error: nil)).isEmpty)
    }

    @Test func skipsSponsorSegmentOnceAndCountsItAsWatched() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        tracker.setSegments([SponsorSegment(category: "sponsor", start: 30, end: 75)], videoId: "a")
        _ = tracker.handle(.startFile(entryId: 1))
        _ = tracker.handle(.playbackRestart)
        #expect(tracker.handle(.propertyChange(name: "time-pos", value: 29.9)).isEmpty)
        #expect(tracker.handle(.propertyChange(name: "time-pos", value: 30.1))
                == [.send(.seekAbsolute(75)),
                    .emit(.skippedSegment(videoId: "a", category: "sponsor", from: 30.1, to: 75))])
        // A keyframe seek may land inside the segment again: no second seek.
        #expect(tracker.handle(.propertyChange(name: "time-pos", value: 74)).isEmpty)
        #expect(emitted(tracker.handle(.endFile(entryId: 1, reason: .stop, error: nil)))
                == [.videoEnded(videoId: "a", position: 75, duration: 600)])
    }

    @Test func segmentsAreSkippedAgainInTheNextEntry() {
        let twice = [playlist[0], playlist[0]]
        var tracker = MPVPlaybackTracker(playlist: twice)
        tracker.setSegments([SponsorSegment(category: "intro", start: 0, end: 10)], videoId: "a")
        for entry in 1...2 {
            _ = tracker.handle(.startFile(entryId: entry))
            _ = tracker.handle(.playbackRestart)
            #expect(tracker.handle(.propertyChange(name: "time-pos", value: 0)).first == .send(.seekAbsolute(10)))
            _ = tracker.handle(.endFile(entryId: entry, reason: .eof, error: nil))
        }
    }

    @Test func noSkippingBeforeStart() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        tracker.setSegments([SponsorSegment(category: "intro", start: 0, end: 10)], videoId: "a")
        _ = tracker.handle(.startFile(entryId: 1))
        #expect(tracker.handle(.propertyChange(name: "time-pos", value: 0)).isEmpty)
    }

    @Test func exitOutcomes() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        #expect(tracker.exit(stopRequested: false, exitCode: 1) == .failed("mpv exited (code 1) without playing anything."))
        #expect(tracker.exit(stopRequested: true, exitCode: 0) == .stopped)
        _ = tracker.handle(.startFile(entryId: 1))
        _ = tracker.handle(.playbackRestart)
        #expect(tracker.exit(stopRequested: false, exitCode: 3) == .finished)
        _ = tracker.handle(.endFile(entryId: 1, reason: .quit, error: nil))
        #expect(tracker.exit(stopRequested: false, exitCode: 0) == .stopped)
    }

    @Test func ignoresUnknownEntries() {
        var tracker = MPVPlaybackTracker(playlist: playlist)
        _ = tracker.handle(.startFile(entryId: 9))
        #expect(tracker.currentIndex == 0)
        #expect(tracker.handle(.endFile(entryId: nil, reason: .eof, error: nil)).isEmpty)
    }
}
