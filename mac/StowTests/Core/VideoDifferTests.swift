import Testing
@testable import Stow

struct VideoDifferTests {
    private func diff(_ sources: [FeedKind: [Video]], seen: [String]?, checked: Set<FeedKind> = []) -> VideoDiff {
        VideoDiffer.diff(sources: sources, seen: seen, checkedFeeds: checked)
    }

    @Test func pastStreamsSeenFirstAreNotNews() {
        let streams = [video("s1", minutesAgo: 1, live: .wasLive), video("s2", minutesAgo: 2, live: .wasLive)]
        let first = diff([.uploads: [video("v1", minutesAgo: 5)], .streams: streams], seen: ["v1"], checked: [.uploads])
        #expect(first.newVideos.isEmpty)
        #expect(first.checkedFeeds == [.uploads, .streams])
        // A stream that ends after that is new.
        let later = diff([.streams: [video("s0", minutesAgo: 0, live: .wasLive)] + streams], seen: first.seenVideoIds, checked: first.checkedFeeds)
        #expect(later.newVideos.map(\.id) == ["s0"])
    }

    @Test func newChannelPutsTwoNewestInInboxAndMarksAllSeen() {
        let fetched = (1...5).map { video("v\($0)", minutesAgo: Double($0)) }
        let result = diff([.uploads: fetched], seen: nil)
        #expect(result.newVideos.map(\.id) == ["v1", "v2"])
        #expect(result.seenVideoIds == ["v1", "v2", "v3", "v4", "v5"])
        #expect(result.checkedFeeds == [.uploads])
    }

    @Test func newChannelCapsBothFeedsAtTwoPreferringDatedVideos() {
        let uploads = [video("p1", minutesAgo: 10), video("p2", minutesAgo: 20)]
        let members = [video("m1", members: true), video("m2", members: true)]
        let result = diff([.uploads: uploads, .members: members], seen: nil)
        #expect(result.newVideos.map(\.id) == ["p1", "p2"])
        #expect(Set(result.seenVideoIds) == ["p1", "p2", "m1", "m2"])
        #expect(result.checkedFeeds == [.uploads, .members])

        let membersOnly = diff([.uploads: [], .members: members + [video("m3", members: true)]], seen: nil)
        #expect(membersOnly.newVideos.map(\.id) == ["m1", "m2"])
    }

    @Test func checkedFeedReturnsEveryUnseenVideoEvenWithoutOverlap() {
        // The whole window turned over while the Mac was off: nothing may be swallowed.
        let fetched = (1...5).map { video("new\($0)") }
        let result = diff([.uploads: fetched], seen: ["old1", "old2"], checked: [.uploads])
        #expect(result.newVideos.map(\.id) == fetched.map(\.id))
        #expect(result.seenVideoIds == fetched.map(\.id) + ["old1", "old2"])
    }

    @Test func laterCheckReturnsOnlyUnseenAndKeepsOldSeenIds() {
        let result = diff([.uploads: [video("new"), video("a"), video("b")]], seen: ["a", "b", "old"], checked: [.uploads])
        #expect(result.newVideos.map(\.id) == ["new"])
        #expect(result.seenVideoIds == ["new", "a", "b", "old"])
    }

    @Test func liveAndUpcomingAreNeitherNewNorSeen() {
        let fetched = [video("live", live: .live), video("soon", live: .upcoming), video("done", live: .wasLive), video("a")]
        let result = diff([.uploads: fetched], seen: ["a"], checked: [.uploads])
        #expect(result.newVideos.map(\.id) == ["done"])
        #expect(result.seenVideoIds == ["done", "a"])
        // Once the premiere airs it is new.
        let later = diff([.uploads: [video("soon", live: .none)]], seen: result.seenVideoIds, checked: [.uploads])
        #expect(later.newVideos.map(\.id) == ["soon"])
    }

    @Test func seenIdsAreCapped() {
        let seen = (0..<VideoDiffer.seenLimit).map { "old\($0)" }
        let result = diff([.uploads: [video("new"), video("old0")]], seen: seen, checked: [.uploads])
        #expect(result.seenVideoIds.count == VideoDiffer.seenLimit)
        #expect(result.seenVideoIds.prefix(2) == ["new", "old0"])
    }

    @Test func membersFeedAppearingLaterAddsOnlyItsTwoNewest() {
        let uploads = [video("p1"), video("p2")]
        let members = (1...6).map { video("m\($0)", members: true) }
        let result = diff([.uploads: uploads, .members: members], seen: ["p1", "p2"], checked: [.uploads])
        #expect(result.newVideos.map(\.id) == ["m1", "m2"])
        #expect(Set(result.seenVideoIds) == Set(["p1", "p2"] + members.map(\.id)))
        let next = diff([.uploads: uploads, .members: [video("m0", members: true)] + members],
                        seen: result.seenVideoIds, checked: result.checkedFeeds)
        #expect(next.newVideos.map(\.id) == ["m0"])
    }

    @Test func emptyFeedCountsAsChecked() {
        let result = diff([.uploads: [video("p1"), video("p2"), video("p3")], .members: []], seen: nil)
        #expect(result.newVideos.map(\.id) == ["p1", "p2"])
        #expect(result.checkedFeeds == [.uploads, .members])
        let next = diff([.members: [video("m1", members: true)]], seen: result.seenVideoIds, checked: result.checkedFeeds)
        #expect(next.newVideos.map(\.id) == ["m1"])
    }
}
