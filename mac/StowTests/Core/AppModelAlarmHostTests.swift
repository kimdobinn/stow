import Foundation
import Testing
@testable import Stow

@MainActor
struct AppModelAlarmHostTests {
    let store = Store(directory: temporaryDirectory())

    func makeModel() -> AppModel {
        let model = AppModel(youtube: FakeYouTube(), account: FakeAccount(), store: store, notifier: FakeNotifier(),
                             cookiesFile: store.directory.appending(path: "cookies.txt"))
        model.load()
        return model
    }

    @Test func recordAlarmRunMergesIdsAndDismissesFromInbox() throws {
        try store.save(AppState(seenVideoIds: [:], inbox: [InboxItem(video: video("a"), foundAt: .now),
                                                           InboxItem(video: video("b"), foundAt: .now)],
                                lastCheck: nil, alarmPlayedIds: ["old"]))
        let model = makeModel()
        let run = AlarmRunRecord(trigger: .test, scheduledFor: .now, startedAt: .now, videoIds: ["a"], outcome: .running)
        model.recordAlarmRun(run, watchedIds: [])
        var finished = run
        finished.outcome = .played
        model.recordAlarmRun(finished, watchedIds: ["a"])

        #expect(model.inbox.map(\.id) == ["b"])
        #expect(model.lastAlarmRun?.outcome == .played)
        let saved = try store.loadState()
        #expect(saved.alarmPlayedIds == ["a", "old"])
        #expect(saved.watchedIds == ["a"])
    }

    @Test func testRunKeepsUnfinishedVideosForTheMorning() throws {
        try store.save(AppState(seenVideoIds: [:], inbox: [InboxItem(video: video("a"), foundAt: .now),
                                                           InboxItem(video: video("b"), foundAt: .now)],
                                lastCheck: nil))
        let model = makeModel()
        model.recordAlarmRun(AlarmRunRecord(trigger: .test, scheduledFor: .now, startedAt: .now, videoIds: ["a", "b"],
                                            outcome: .played), watchedIds: ["b"])
        #expect(model.inbox.map(\.id) == ["a"])
        let saved = try store.loadState()
        #expect(saved.alarmPlayedIds == ["b"])
        #expect(saved.watchedIds == ["b"])
    }

    @Test func testRunKeepsTheLastScheduledAlarm() throws {
        let eight = Date(timeIntervalSince1970: 1_763_539_200)
        let model = makeModel()
        model.recordAlarmRun(AlarmRunRecord(trigger: .scheduled, scheduledFor: eight, startedAt: eight, videoIds: [],
                                            outcome: .played), watchedIds: [])
        model.recordAlarmRun(AlarmRunRecord(trigger: .test, scheduledFor: eight + 60, startedAt: eight + 60, videoIds: [],
                                            outcome: .played), watchedIds: [])
        let saved = try store.loadState()
        #expect(saved.lastAlarmRun?.trigger == .test)
        #expect(saved.lastScheduledAlarm == eight)
    }

    @Test func lastScheduledAlarmFallsBackToAnOlderLastRun() throws {
        let json = """
        {"lastAlarmRun": {"trigger": "scheduled", "scheduledFor": "2026-11-19T08:00:00Z", "startedAt": "2026-11-19T07:57:00Z",
                          "videoIds": [], "outcome": "played"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(AppState.self, from: Data(json.utf8))
        #expect(state.lastScheduledAlarm == state.lastAlarmRun?.scheduledFor)
        #expect(state.lastScheduledAlarm != nil)
    }

    @Test func updateAlarmSettingsPersists() throws {
        let model = makeModel()
        model.updateAlarmSettings { $0.volume = 55 }
        #expect(model.alarmSettings.volume == 55)
        #expect(try store.loadSettings().alarm.volume == 55)
    }

    @Test func playbackCookiesNeedAFile() {
        let model = makeModel()
        #expect(model.playbackCookiesFile == nil)
    }
}
