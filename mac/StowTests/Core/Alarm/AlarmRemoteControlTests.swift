import Foundation
import Testing
@testable import Stow

/// The controller as the phone remote sees it.
@MainActor
struct AlarmRemoteControlTests {
    let fakes = FakeAlarmServices()
    let host = FakeAlarmHost(state: AppState(seenVideoIds: [:], inbox: [
        InboxItem(video: video("a", minutesAgo: 20), foundAt: .now),
        InboxItem(video: video("b", minutesAgo: 10), foundAt: .now),
    ], lastCheck: nil))

    private func makeController() -> AlarmController {
        let controller = AlarmController(services: fakes.services)
        controller.host = host
        return controller
    }

    @Test func remoteFollowsTheRunFromPrepToItsEnd() async throws {
        fakes.player.script.withLock { $0 = [.started(index: 0, videoId: "a"), .exited(.finished)] }
        let controller = makeController()
        controller.testNow()
        #expect(fakes.remote.phases.first == .preparing(scheduledFor: try #require(controller.runner?.scheduledFor)))
        let ended = await AlarmWaiting.poll(within: .seconds(5)) { controller.phase == .idle }
        try #require(ended)
        #expect(fakes.remote.phases.contains(.starting(output: "JBL Go 3")))
        #expect(fakes.remote.phases.last == .idle)
    }

    @Test func statusVolumeAndActionsWhilePlaying() async throws {
        let now = NowPlaying(index: 0, count: 2, video: video("a"), isLoading: false, isPaused: false, position: 3,
                             duration: 600, upNext: video("b"))
        fakes.player.current.withLock { $0 = now }
        fakes.player.script.withLock { $0 = [.started(index: 0, videoId: "a")] }
        let controller = makeController()
        #expect(await controller.runStatus() == .ended)
        controller.testNow()
        let playing = await AlarmWaiting.poll(within: .seconds(5)) {
            if case .playing = controller.phase { true } else { false }
        }
        try #require(playing)

        var status = await controller.runStatus()
        #expect(status.playlist.map(\.id) == ["a", "b"])
        #expect(status.nowPlaying == now)
        #expect(status.outputName == "JBL Go 3")
        #expect(status.volume == 80)

        controller.setOutputVolume(30)
        status = await controller.runStatus()
        #expect(status.volume == 30)
        await controller.perform(.next)
        #expect(fakes.player.actions.withLock { $0 } == [.next])
        #expect(Set(controller.knownVideos.map(\.id)) == ["a", "b"])

        controller.pushToPhones(["type": "alarm"])
        #expect(host.pushes == [["type": "alarm"]])

        controller.stop()
        let ended = await AlarmWaiting.poll(within: .seconds(5)) { controller.phase == .idle }
        try #require(ended)
        #expect(await controller.runStatus() == .ended)
        // Actions after the run do nothing.
        await controller.perform(.next)
        #expect(fakes.player.actions.withLock { $0 }.count == 1)
    }
}
