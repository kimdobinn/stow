import Foundation
import Synchronization
import Testing
@testable import Stow

struct AlarmPlannerTests {
    /// The `video(_:minutesAgo:)` helper dates videos relative to this.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: Double = 24 * 60

    func item(_ video: Video, found: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> InboxItem {
        InboxItem(video: video, foundAt: found)
    }

    func rounds(_ alarm: AlarmSettings = .default, channels: [Channel] = [alarmChannel()], state: AppState,
                seed: UInt64 = 1) -> [AlarmPlanner.Round] {
        var generator = SeededGenerator(seed: seed)
        return AlarmPlanner.rounds(settings: alarm, channels: channels, state: state, now: now, using: &generator)
    }

    // MARK: Inbox candidates

    @Test func inboxOldestFirstByDefault() {
        let state = AppState(seenVideoIds: [:], inbox: [item(video("new", minutesAgo: 10)), item(video("old", minutesAgo: 300)),
                                                        item(video("mid", minutesAgo: 60))], lastCheck: nil)
        #expect(AlarmPlanner.inboxCandidates(settings: .default, channels: [alarmChannel()], state: state).map(\.id)
                == ["old", "mid", "new"])
        var newest = AlarmSettings.default
        newest.order = .newestFirst
        #expect(AlarmPlanner.inboxCandidates(settings: newest, channels: [alarmChannel()], state: state).map(\.id)
                == ["new", "mid", "old"])
    }

    @Test func undatedVideosCountAsPublishedWhenFound() {
        let found = now.addingTimeInterval(-120 * 60)
        let state = AppState(seenVideoIds: [:], inbox: [item(video("members", members: true), found: found),
                                                        item(video("dated", minutesAgo: 60))], lastCheck: nil,
                             memberAccess: ["members": .watchable])
        #expect(AlarmPlanner.inboxCandidates(settings: .default, channels: [alarmChannel()], state: state).map(\.id)
                == ["members", "dated"])
    }

    @Test func lockedMembersVideosAreSkipped() {
        let state = AppState(seenVideoIds: [:], inbox: [item(video("locked", minutesAgo: 30, members: true)),
                                                        item(video("open", minutesAgo: 20, members: true))],
                             lastCheck: nil, memberAccess: ["locked": .locked(level: "Gold"), "open": .watchable])
        #expect(AlarmPlanner.inboxCandidates(settings: .default, channels: [alarmChannel()], state: state).map(\.id) == ["open"])
    }

    @Test func inboxSkipsPlayedLiveAndNonMorningChannels() {
        let state = AppState(
            seenVideoIds: [:],
            inbox: [item(video("ok", minutesAgo: 1)), item(video("played", minutesAgo: 2)),
                    item(video("live", minutesAgo: 3, live: .live)), item(video("soon", minutesAgo: 4, live: .upcoming)),
                    item(video("night", channel: "UCnight", minutesAgo: 5)), item(video("gone", channel: "UCgone", minutesAgo: 6))],
            lastCheck: nil, alarmPlayedIds: ["played"])
        let channels = [alarmChannel(), alarmChannel("UCnight", morning: false)]
        #expect(AlarmPlanner.inboxCandidates(settings: .default, channels: channels, state: state).map(\.id) == ["ok"])
    }

    @Test func previewTakesMaxVideosFromTheInbox() {
        var alarm = AlarmSettings.default
        alarm.maxVideos = 2
        let state = AppState(seenVideoIds: [:], inbox: (1...4).map { item(video("v\($0)", minutesAgo: Double($0))) },
                             lastCheck: nil)
        #expect(AlarmPlanner.preview(rounds(alarm, state: state)) == AlarmPreview(
            videos: [video("v4", minutesAgo: 4), video("v3", minutesAgo: 3)], fallbackRule: nil))
    }

    // MARK: Fallback rules

    func recentState(played: [String] = []) -> AppState {
        AppState(seenVideoIds: [:], inbox: [], recentVideos: [
            "UCtest": [video("a1", minutesAgo: 60), video("a2", minutesAgo: 3 * day), video("a3", minutesAgo: 20 * day)],
            "UCother": [video("b1", channel: "UCother", minutesAgo: 30), video("b2", channel: "UCother", minutesAgo: 2 * day)],
            "UCnight": [video("n1", channel: "UCnight", minutesAgo: 1)],
            "UCunfollowed": [video("u1", channel: "UCunfollowed", minutesAgo: 1)],
        ], lastCheck: nil, alarmPlayedIds: played)
    }

    let channels = [alarmChannel(), alarmChannel("UCother"), alarmChannel("UCnight", morning: false)]

    func candidates(_ rule: FallbackRule, state: AppState, seed: UInt64 = 1) -> [String] {
        var generator = SeededGenerator(seed: seed)
        return AlarmPlanner.candidates(for: rule, channels: channels, state: state, now: now, using: &generator).map(\.id)
    }

    @Test func mostRecentUnplayedAnyChannel() {
        let rule = FallbackRule(kind: .mostRecentUnplayed, withinDays: 7)
        #expect(candidates(rule, state: recentState()) == ["b1", "a1", "b2", "a2"])
        #expect(candidates(rule, state: recentState(played: ["b1", "a1"])) == ["b2", "a2"])
    }

    @Test func mostRecentUnplayedRespectsDaysAndChannel() {
        #expect(candidates(FallbackRule(kind: .mostRecentUnplayed, withinDays: 1), state: recentState()) == ["b1", "a1"])
        #expect(candidates(FallbackRule(kind: .mostRecentUnplayed, channelId: "UCtest", withinDays: 30), state: recentState())
                == ["a1", "a2", "a3"])
        // A specific channel is used even with morning off; one that isn't followed yields nothing.
        #expect(candidates(FallbackRule(kind: .mostRecentUnplayed, channelId: "UCnight"), state: recentState()) == ["n1"])
        #expect(candidates(FallbackRule(kind: .mostRecentUnplayed, channelId: "UCunfollowed"), state: recentState()).isEmpty)
    }

    @Test func randomUnplayedIsAShuffleOfTheUnplayedRecentVideos() {
        let rule = FallbackRule(kind: .randomUnplayed, withinDays: 7)
        let picked = candidates(rule, state: recentState(played: ["a1"]), seed: 42)
        #expect(Set(picked) == ["b1", "b2", "a2"])
        #expect(picked == candidates(rule, state: recentState(played: ["a1"]), seed: 42))
        let orders = Set((0..<20).map { candidates(rule, state: recentState(played: ["a1"]), seed: $0) })
        #expect(orders.count > 1)
    }

    @Test func replayLatestIncludesPlayedVideos() {
        let state = recentState(played: ["a1", "b1"])
        #expect(candidates(FallbackRule(kind: .replayLatest), state: state).first == "b1")
        #expect(candidates(FallbackRule(kind: .replayLatest, channelId: "UCtest"), state: state) == ["a1", "a2", "a3"])
    }

    @Test func fallbackRulesApplyInOrderWhenTheInboxIsEmpty() {
        var alarm = AlarmSettings.default
        alarm.fallbackRules = [FallbackRule(kind: .mostRecentUnplayed, channelId: "UCunfollowed"),
                               FallbackRule(kind: .mostRecentUnplayed, withinDays: 1), FallbackRule(kind: .replayLatest)]
        let preview = AlarmPlanner.preview(rounds(alarm, channels: channels, state: recentState()))
        #expect(preview.videos.map(\.id) == ["b1"])
        #expect(preview.fallbackRule == alarm.fallbackRules[1])
    }

    @Test func nothingAnywhereGivesAnEmptyPreview() {
        #expect(AlarmPlanner.preview(rounds(state: .empty)) == .empty)
    }

    // MARK: Checking details

    func plan(_ rounds: [AlarmPlanner.Round], maxMinutes: Int = 60, details: FakeAlarmDetails) async -> AlarmPlanner.Plan {
        await AlarmPlanner.plan(rounds, maxDurationMinutes: maxMinutes) { await details.details(for: $0, cookiesFile: nil) }
    }

    @Test func dropsLongLiveAndUnplayableVideosAndKeepsOrder() async {
        let details = FakeAlarmDetails()
        details.known.withLock {
            $0["long"] = VideoDetails(id: "long", duration: 3 * 3600, liveStatus: .none, isPlayable: true, error: nil)
            $0["live"] = VideoDetails(id: "live", duration: nil, liveStatus: .live, isPlayable: true, error: nil)
            $0["members"] = VideoDetails(id: "members", duration: nil, liveStatus: .unknown, isPlayable: false, error: "members only")
        }
        let state = AppState(seenVideoIds: [:], inbox: ["ok1", "long", "live", "members", "ok2", "ok3", "ok4"].enumerated().map {
            item(video($0.element, minutesAgo: Double(100 - $0.offset)))
        }, lastCheck: nil)
        let result = await plan(rounds(state: state), details: details)
        #expect(result.videos.map(\.video.id) == ["ok1", "ok2", "ok3"])
        #expect(result.videos.first?.duration == 600)
        #expect(result.fallbackRule == nil)
        #expect(result.skipped.map(\.video.id) == ["long", "live", "members"])
        #expect(result.skipped.first?.reason == "longer than 60 min (180 min)")
        // ok4 is never looked up.
        #expect(!details.requested.withLock { $0 }.joined().contains("ok4"))
    }

    @Test func fallsBackWhenNoInboxVideoIsPlayable() async {
        let details = FakeAlarmDetails()
        details.known.withLock {
            $0["x"] = VideoDetails(id: "x", duration: 7200, liveStatus: .none, isPlayable: true, error: nil)
            $0["b1"] = VideoDetails(id: "b1", duration: nil, liveStatus: .none, isPlayable: false, error: "gone")
        }
        var state = recentState()
        state.inbox = [item(video("x", minutesAgo: 1))]
        let result = await plan(rounds(channels: channels, state: state), details: details)
        #expect(result.videos.map(\.video.id) == ["a1"])
        #expect(result.fallbackRule == FallbackRule(kind: .mostRecentUnplayed, withinDays: 7))
        #expect(result.skipped.map(\.video.id) == ["x", "b1"])
    }

    @Test func lookupsAreCapped() async {
        let details = FakeAlarmDetails()
        let ids = (0..<30).map { "v\($0)" }
        details.known.withLock { known in
            for id in ids { known[id] = VideoDetails(id: id, duration: nil, liveStatus: .none, isPlayable: false, error: "no") }
        }
        let state = AppState(seenVideoIds: [:], inbox: ids.map { item(video($0, minutesAgo: 1)) }, lastCheck: nil)
        let result = await plan(rounds(state: state), details: details)
        #expect(result.videos.isEmpty)
        #expect(details.requested.withLock { $0 }.joined().count == AlarmPlanner.maxLookups)
    }

    @Test func rejectedInboxVideosCantStarveTheFallbackRules() async {
        let details = FakeAlarmDetails()
        let long = (0..<20).map { "long\($0)" }
        details.known.withLock { known in
            for id in long { known[id] = VideoDetails(id: id, duration: 7200, liveStatus: .none, isPlayable: true, error: nil) }
        }
        var state = recentState()
        state.inbox = long.map { item(video($0, minutesAgo: 1)) }
        let result = await plan(rounds(channels: channels, state: state), details: details)
        #expect(result.videos.map(\.video.id) == ["b1"])
        #expect(result.fallbackRule == FallbackRule(kind: .mostRecentUnplayed, withinDays: 7))
        #expect(details.requested.withLock { $0 }.joined().count <= AlarmPlanner.maxLookups)
    }

    @Test func uncheckedPlanIsThePreview() {
        let state = AppState(seenVideoIds: [:], inbox: [item(video("a", minutesAgo: 1))], lastCheck: nil)
        let plan = AlarmPlanner.unchecked(rounds(state: state))
        #expect(plan.videos == [PlayableVideo(video: video("a", minutesAgo: 1), duration: nil)])
    }

    @Test(arguments: [(90.0, 100.0, true), (89.9, 100.0, false), (100.0, nil, false), (5.0, 0.0, false)] as [(Double, Double?, Bool)])
    func watchedAtNinetyPercent(position: Double, duration: Double?, expected: Bool) {
        #expect(AlarmPlanner.isWatched(position: position, duration: duration) == expected)
    }

    @Test func seededGeneratorIsStablePerDay() {
        let calendar = AlarmScheduleTests.calendar
        var morning = SeededGenerator(day: AlarmScheduleTests.date(2026, 11, 18, 7), calendar: calendar)
        var evening = SeededGenerator(day: AlarmScheduleTests.date(2026, 11, 18, 22), calendar: calendar)
        var tomorrow = SeededGenerator(day: AlarmScheduleTests.date(2026, 11, 19, 7), calendar: calendar)
        let first = morning.next()
        #expect(first == evening.next())
        #expect(first != tomorrow.next())
    }
}
