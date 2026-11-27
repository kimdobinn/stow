import AVFoundation
import Foundation
import StowKit
import Testing
@testable import Stow

/// The player on a demo repository, with small generated videos standing in for downloads.
@MainActor
@Suite(.serialized) struct PlaybackTests {
    let repository: Repository
    let shell: Shell
    let controller: PlaybackController
    /// Two of the demo's videos (from YouTube's feeds, so not queued for download).
    let first = "dQw4w9WgXcQ"
    let second = "yPYZpwSpKmA"

    init() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "playback-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "playback-tests-\(UUID().uuidString)")!
        repository = Repository(config: nil, youtube: YtDlpTool(ytdlp: FakeYtDlp()), demo: true, defaults: defaults,
                                directory: directory, tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline))
        repository.start()
        shell = Shell(repository: repository)
        controller = PlaybackController(repository: repository)
        shell.player = controller
    }

    /// Writes a short video and marks it downloaded.
    private func download(_ id: String, seconds: Int = 2) async throws {
        let file = repository.local.downloadsDirectory.appending(path: "\(id).mp4")
        try await TestMedia.writeVideo(to: file, seconds: seconds)
        repository.local.update(id) { _ in
            LocalVideo(id: id, state: .downloaded, progress: 100, fileName: file.lastPathComponent, sizeBytes: 1000, sentAt: .now)
        }
    }

    private func eventually(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func playsADownloadFromItsFileAndMarksItWatched() async throws {
        try await download(first)
        try #require(repository.item(first)?.isPlayable == true)
        #expect(repository.item(first)?.watched == false)
        controller.play(PlaybackRequest(queue: [first], startId: first))
        #expect(controller.currentId == first)
        #expect(!controller.isStreaming)
        #expect(controller.fileURL != nil)
        #expect(await eventually { controller.position > 0.3 })
        #expect(controller.isPlaying)
        // Autoplay is off: it stops at the end with "You're done", and it's now watched.
        #expect(await eventually { controller.ended })
        #expect(repository.item(first)?.watched == true)
        #expect(!controller.isPlaying)
        // Replay starts over.
        controller.resume()
        #expect(!controller.ended)
        #expect(await eventually { controller.isPlaying && controller.position < 1.5 })
        controller.stop()
        #expect(controller.currentId == nil)
        #expect(controller.player.currentItem == nil)
    }

    @Test func autoplayMovesOnThroughTheQueue() async throws {
        try await download(first, seconds: 1)
        try await download(second, seconds: 1)
        repository.prefs.autoplay = true
        defer { repository.prefs.autoplay = false }
        controller.play(PlaybackRequest(queue: [first, second], startId: first))
        #expect(controller.hasNext)
        #expect(!controller.hasPrevious)
        #expect(controller.upNext.map(\.id) == [second])
        #expect(await eventually { controller.currentId == second })
        #expect(controller.hasPrevious)
        #expect(controller.upNext.isEmpty)
        #expect(await eventually { controller.ended })
        controller.previous()
        #expect(controller.currentId == first)
        controller.stop()
    }

    @Test func resumesWhereYouLeftOffUnlessFinished() async throws {
        try await download(first, seconds: 4)
        repository.savePosition(first, positionMs: 2_000, durationMs: 4_000)
        controller.play(PlaybackRequest(queue: [first], startId: first))
        #expect(await eventually { controller.position >= 2 && controller.isPlaying })
        controller.stop()
        // Saved on stop, so the next play carries on from there.
        #expect((repository.item(first)?.local?.positionMs ?? 0) >= 2_000)

        repository.savePosition(first, positionMs: 3_900, durationMs: 4_000)
        controller.play(PlaybackRequest(queue: [first], startId: first))
        #expect(await eventually { controller.isPlaying && controller.player.currentItem?.status == .readyToPlay })
        #expect(controller.position < 2)
        controller.stop()
    }

    @Test func speedAndHold() async throws {
        try await download(first, seconds: 4)
        controller.play(PlaybackRequest(queue: [first], startId: first))
        #expect(await eventually { controller.isPlaying })
        controller.setSpeed(1.5)
        #expect(repository.prefs.playbackSpeed == 1.5)
        #expect(controller.player.rate == 1.5)
        controller.beginHold()
        #expect(controller.isHolding)
        #expect(controller.player.rate == PlaybackController.holdRate)
        controller.endHold()
        #expect(controller.player.rate == 1.5)
        controller.setSpeed(1)
        controller.stop()
    }

    @Test func skipsAndSeeksWithinTheVideo() async throws {
        try await download(first, seconds: 4)
        controller.play(PlaybackRequest(queue: [first], startId: first))
        #expect(await eventually { controller.player.currentItem?.status == .readyToPlay })
        controller.pause()
        controller.seek(to: 1)
        controller.skip(forward: true)
        #expect(controller.position == min(1 + PlaybackController.skipSeconds, controller.duration))
        controller.skip(forward: false)
        controller.skip(forward: false)
        #expect(controller.position >= 0)
        controller.stop()
    }

    @Test func deletingWhatPlaysClosesThePlayer() async throws {
        try await download(first)
        let item = try #require(repository.item(first))
        shell.play([item], start: item)
        controller.play(try #require(shell.playback))
        shell.actions.delete(item)
        #expect(shell.playback == nil)
        #expect(repository.item(first)?.isPlayable == false)
    }

    @Test func framesWhileScrubbing() async throws {
        try await download(first, seconds: 3)
        let frames = ScrubFrames()
        frames.use(repository.fileURL(for: first))
        frames.show(1.5)
        #expect(await eventually { frames.image != nil })
    }
}

/// What a waiting download says, and when the app is about to be suspended.
@MainActor
@Suite struct DownloadWaitTests {
    @Test func saysWhatItWaitsFor() {
        let item = VideoItem(video: Video(id: "x", channelId: "c", channelTitle: "C", title: "T", publishedAt: nil,
                                          thumbnailURL: nil, isMembersOnly: false),
                             sent: nil, local: LocalVideo(id: "x", state: .queued, sentAt: .now), watchedOnMac: false)
        #expect(DownloadText.waiting(item, hold: .none) == "Waiting to download")
        #expect(DownloadText.waiting(item, hold: .waitingForWiFi) == "Waiting for Wi-Fi")
        #expect(DownloadText.waiting(item, hold: .noConnection) == "Waiting for a connection")
        var failed = item
        failed.local?.error = "HTTP Error 403"
        #expect(DownloadText.waiting(failed, hold: .none) == "Retrying soon")
        #expect(DownloadText.banner(.waitingForWiFi, waiting: 0) == nil)
        #expect(DownloadText.banner(.none, waiting: 3) == nil)
        #expect(DownloadText.banner(.noConnection, waiting: 1) != nil)
    }

    @Test func runningOutOfTimePausesUntilTheAppIsBack() {
        let defaults = UserDefaults(suiteName: "wait-tests-\(UUID().uuidString)")!
        let directory = FileManager.default.temporaryDirectory.appending(path: "wait-tests-\(UUID().uuidString)")
        let repository = Repository(config: nil, youtube: YtDlpTool(ytdlp: FakeYtDlp()), demo: true, defaults: defaults,
                                    directory: directory, tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline))
        repository.start()
        let keeper = BackgroundDownloads(repository: repository)
        // The demo queues one sent video, which waits for a network here.
        #expect(!repository.downloads.queuedIds.isEmpty)
        keeper.timeRunningOut()
        #expect(repository.downloads.isSuspended)
        #expect(repository.downloads.hold == .suspended)
        keeper.appBecameActive()
        #expect(!repository.downloads.isSuspended)
    }
}
