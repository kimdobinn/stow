import Foundation
import Testing
@testable import Stow

@MainActor
struct AlarmRunnerTests {
    let fakes = FakeAlarmServices()
    let host = FakeAlarmHost(state: AppState(seenVideoIds: [:], inbox: [
        InboxItem(video: video("a", minutesAgo: 20), foundAt: .now),
        InboxItem(video: video("b", minutesAgo: 10), foundAt: .now),
    ], lastCheck: nil))

    func makeRunner(trigger: AlarmTrigger = .test) -> (AlarmRunner, PhaseLog) {
        let phases = PhaseLog()
        let runner = AlarmRunner(trigger: trigger, scheduledFor: .now, services: fakes.services, host: host) {
            phases.list.append($0)
        }
        return (runner, phases)
    }

    final class PhaseLog {
        var list: [AlarmPhase] = []
    }

    @Test func playsInboxVideosOnTheSpeakerAndRecordsTheRun() async {
        fakes.player.script.withLock {
            $0 = [.started(index: 0, videoId: "a"), .videoEnded(videoId: "a", position: 95, duration: 100),
                  .started(index: 1, videoId: "b"), .videoEnded(videoId: "b", position: 30, duration: nil),
                  .exited(.finished)]
        }
        let (runner, phases) = makeRunner()
        await runner.run()

        #expect(host.refreshes == 1)
        #expect(fakes.player.plays.withLock { $0.first?.ids } == ["a", "b"])
        #expect(fakes.player.plays.withLock { $0.first?.output } == alarmJBL.uid)
        #expect(fakes.outputs.volumes.withLock { $0 } == [alarmJBL.uid: 0.8])
        #expect(fakes.power.displayWakes == 1)
        #expect(fakes.sound.plays.isEmpty)

        let run = host.runs.last
        #expect(run?.outcome == .played)
        #expect(run?.videoIds == ["a", "b"])
        #expect(run?.output == "JBL Go 3")
        #expect(run?.endedAt != nil)
        #expect(run?.fallbackRule == nil)
        // b's 30 s of its 600 s (from the details) isn't watched.
        #expect(host.watched == ["a"])
        // Recorded as running when the first video started, so a crash can't replay it.
        #expect(host.runs.first?.outcome == .running)
        #expect(host.runs.first?.videoIds == ["a"])
        #expect(phases.list.first == .preparing(scheduledFor: runner.scheduledFor))
        #expect(phases.list.contains(.starting(output: "JBL Go 3")))
        #expect(phases.list.contains(.playing(index: 1, count: 2, video: video("b", minutesAgo: 10))))
    }

    @Test func playerFailureSoundsTheAlarm() async {
        fakes.player.failure.withLock { $0 = .toolNotFound("mpv") }
        let (runner, phases) = makeRunner()
        await runner.run()

        #expect(fakes.sound.plays == [alarmJBL.uid])
        #expect(host.runs.last?.outcome == .alarmSound)
        #expect(host.runs.last?.error?.contains("mpv not found") == true)
        #expect(host.problems == ["The alarm couldn't play videos"])
        #expect(phases.list.contains { if case .alarmSound = $0 { true } else { false } })
    }

    @Test func nothingToPlaySoundsTheAlarm() async {
        host.currentState.inbox = []
        let (runner, _) = makeRunner()
        await runner.run()

        #expect(fakes.player.plays.withLock { $0 }.isEmpty)
        #expect(fakes.sound.plays == [alarmJBL.uid])
        #expect(host.runs.last?.outcome == .alarmSound)
    }

    @Test func everyVideoFailingToLoadSoundsTheAlarm() async {
        fakes.player.script.withLock {
            $0 = [.loadFailed(videoId: "a", message: "403"), .loadFailed(videoId: "b", message: "410"), .exited(.finished)]
        }
        let (runner, _) = makeRunner()
        await runner.run()

        #expect(host.runs.last?.outcome == .alarmSound)
        #expect(host.runs.last?.error == "No video could be streamed: 410")
    }

    @Test func alarmSoundFallsBackToTheDefaultOutputThenFails() async {
        fakes.player.failure.withLock { $0 = .player("boom") }
        fakes.sound.failingDevices = [alarmJBL.uid]
        let (runner, _) = makeRunner()
        await runner.run()
        #expect(fakes.sound.plays == [alarmJBL.uid, nil])
        #expect(host.runs.last?.outcome == .alarmSound)

        fakes.sound.failingDevices = [alarmJBL.uid, ""]
        let (second, _) = makeRunner()
        await second.run()
        #expect(host.runs.last?.outcome == .failed)
    }

    @Test func missingSpeakerIsConnectedFirst() async {
        fakes.outputs.list.withLock { $0.removeAll { $0 == alarmJBL } }
        fakes.speaker.connectAdds = alarmJBL
        fakes.player.script.withLock { $0 = [.started(index: 0, videoId: "a"), .exited(.finished)] }
        let (runner, _) = makeRunner()
        await runner.run()

        #expect(fakes.speaker.connects == 1)
        #expect(host.runs.last?.output == "JBL Go 3")
    }

    @Test func unreachableSpeakerFallsBackToTheMonitor() async {
        fakes.outputs.list.withLock { $0.removeAll { $0 == alarmJBL } }
        fakes.player.script.withLock { $0 = [.started(index: 0, videoId: "a"), .exited(.finished)] }
        let (runner, _) = makeRunner()
        await runner.run()

        #expect(fakes.speaker.connects == 1)
        #expect(fakes.player.plays.withLock { $0.first?.output } == alarmMonitor.uid)
        #expect(fakes.outputs.volumes.withLock { $0 } == [alarmMonitor.uid: 0.8])
        #expect(host.runs.last?.output == "Mi monitor")
        #expect(host.logs.contains { $0.contains("JBL Go 3 isn't available; using Mi monitor") })
    }

    @Test func outputPreferenceOrder() {
        let alarm = AlarmSettings.default
        #expect(AlarmRunner.preferredOutput(for: alarm, in: [alarmCRG, alarmMonitor, alarmJBL]) == alarmJBL)
        #expect(AlarmRunner.preferredOutput(for: alarm, in: [alarmCRG, alarmBuiltIn, alarmMonitor]) == alarmMonitor)
        #expect(AlarmRunner.preferredOutput(for: alarm, in: [alarmCRG, alarmBuiltIn]) == alarmBuiltIn)
        let renamedBuiltIn = AudioOutput(uid: "BuiltIn", name: "Speakers", transport: .builtIn, isDefault: false)
        #expect(AlarmRunner.preferredOutput(for: alarm, in: [alarmCRG, renamedBuiltIn]) == renamedBuiltIn)
        #expect(AlarmRunner.preferredOutput(for: alarm, in: [alarmCRG]) == alarmCRG)
        #expect(AlarmRunner.preferredOutput(for: alarm, in: []) == nil)
    }

    @Test func stopWhilePlayingEndsTheRunAsPlayed() async throws {
        fakes.player.script.withLock { $0 = [.started(index: 0, videoId: "a")] }
        let (runner, phases) = makeRunner()
        let task = Task { await runner.run() }
        let playing = await AlarmWaiting.poll(within: .seconds(5)) {
            phases.list.contains { if case .playing = $0 { true } else { false } }
        }
        try #require(playing)
        runner.stop()
        await task.value

        #expect(host.runs.last?.outcome == .played)
        #expect(host.runs.last?.videoIds == ["a"])
        #expect(fakes.sound.plays.isEmpty)
    }

    @Test func videosAddedFromThePhoneJoinThePlaylistAndTheRecord() async {
        let added = PlayableVideo(video: video("x"), duration: 100)
        fakes.player.script.withLock {
            $0 = [.started(index: 0, videoId: "a"), .appended(added), .started(index: 2, videoId: "x"),
                  .videoEnded(videoId: "x", position: 95, duration: nil), .exited(.finished)]
        }
        let (runner, phases) = makeRunner()
        await runner.run()

        #expect(runner.playlist.map(\.video.id) == ["a", "b", "x"])
        #expect(phases.list.contains(.playing(index: 2, count: 3, video: video("x"))))
        #expect(host.runs.last?.videoIds == ["a", "x"])
        // Watched by the duration it was added with.
        #expect(host.watched == ["x"])
        #expect(host.logs.contains { $0.contains("added “Video x”") })
    }

    @Test func volumeFromThePhoneBeforeTheOutputIsChosenReplacesTheSetting() async {
        fakes.player.script.withLock { $0 = [.started(index: 0, videoId: "a"), .exited(.finished)] }
        let (runner, _) = makeRunner()
        #expect(runner.outputVolume == host.currentSettings().alarm.volume)
        runner.setOutputVolume(140)
        #expect(runner.outputVolume == 100)
        runner.setOutputVolume(55)
        await runner.run()
        #expect(fakes.outputs.volumes.withLock { $0 } == [alarmJBL.uid: 0.55])
        #expect(runner.output == alarmJBL)
    }

    @Test func stopDuringPrepRecordsNothingPlayed() async {
        let (runner, _) = makeRunner()
        runner.stop()
        await runner.run()

        #expect(fakes.player.plays.withLock { $0 }.isEmpty)
        #expect(fakes.sound.plays.isEmpty)
        #expect(host.runs.last?.outcome == .stopped)
        #expect(host.runs.last?.error == "Stopped before anything played.")
    }

    @Test func abandonedRunIsNotRecorded() async {
        let (runner, _) = makeRunner(trigger: .scheduled)
        runner.abandon()
        await runner.run()
        #expect(host.runs.isEmpty)
    }

    @Test func lateScheduledRunSkipsTheRefreshAndPlaysAtOnce() async {
        fakes.player.script.withLock { $0 = [.started(index: 0, videoId: "a"), .exited(.finished)] }
        let runner = AlarmRunner(trigger: .scheduled, scheduledFor: .now.addingTimeInterval(-6 * 60),
                                 services: fakes.services, host: host) { _ in }
        await runner.run()
        #expect(host.refreshes == 0)
        #expect(host.runs.last?.outcome == .played)
    }

    @Test func playerThatNeverStartsAVideoSoundsTheAlarm() async {
        let (runner, _) = makeRunner()
        runner.startLimit = .milliseconds(300)
        await runner.run()

        #expect(fakes.player.plays.withLock { $0.count } == 1)
        #expect(fakes.sound.plays == [alarmJBL.uid])
        #expect(host.runs.last?.outcome == .alarmSound)
        #expect(host.runs.last?.error?.hasPrefix("No video started within") == true)
    }

    @Test func outputVolumeIsPutBackAfterTheRun() async {
        fakes.outputs.volumes.withLock { $0[alarmJBL.uid] = 0.3 }
        fakes.player.script.withLock { $0 = [.started(index: 0, videoId: "a"), .exited(.finished)] }
        let (runner, phases) = makeRunner()
        await runner.run()
        #expect(phases.list.contains(.starting(output: "JBL Go 3")))
        #expect(fakes.outputs.volumes.withLock { $0[alarmJBL.uid] } == 0.3)
    }

    @Test func fallbackOutputThatReturnsWithTheDisplayIsUsed() async {
        fakes.outputs.list.withLock { $0 = [alarmCRG, alarmBuiltIn] }
        fakes.player.script.withLock { $0 = [.started(index: 0, videoId: "a"), .exited(.finished)] }
        let outputs = fakes.outputs
        Task {
            try? await Task.sleep(for: .seconds(1))
            outputs.list.withLock { $0.append(alarmMonitor) }
        }
        let (runner, _) = makeRunner()
        await runner.run()
        #expect(host.runs.last?.output == "Mi monitor")
    }
}
