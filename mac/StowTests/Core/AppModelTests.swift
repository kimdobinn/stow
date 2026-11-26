import Foundation
import Testing
@testable import Stow

@MainActor
struct AppModelTests {
    let youtube = FakeYouTube()
    let account = FakeAccount()
    let notifier = FakeNotifier()
    let store = Store(directory: temporaryDirectory())
    let info = ChannelInfo(id: "UC-XMoeMXbYrMlvmyLSwDd3g", title: "Jack Hopkins", handle: "@JackhopkinsCEO", avatarURL: nil)

    func makeModel() -> AppModel {
        let model = AppModel(youtube: youtube, account: account, store: store, notifier: notifier,
                             cookiesFile: store.directory.appending(path: "cookies.txt"))
        model.load()
        return model
    }

    func setUpChannel() {
        youtube.channels.withLock { $0["@JackhopkinsCEO"] = info }
        youtube.publicFeeds.withLock { $0[info.id] = (1...5).map { video("v\($0)", channel: info.id, minutesAgo: Double($0)) } }
    }

    @Test func addChannelSeedsTwoNewestAndPersists() async throws {
        setUpChannel()
        let model = makeModel()
        let channel = try await model.addChannel(input: "  @JackhopkinsCEO\n")
        #expect(channel.morning)
        #expect(model.inbox.map(\.id) == ["v1", "v2"])
        #expect(model.inbox.first?.video.channelTitle == "Jack Hopkins")
        #expect(notifier.newVideoBatches.isEmpty)

        #expect(try store.loadSettings().channels == [channel])
        #expect(try store.loadState().seenVideoIds[info.id]?.count == 5)

        await #expect(throws: StowError.channelAlreadyAdded("Jack Hopkins")) {
            try await model.addChannel(input: "@JackhopkinsCEO")
        }
    }

    @Test func recentFeedListsChannelVideosAndDismissedOnes() async throws {
        setUpChannel()
        let model = makeModel()
        try await model.addChannel(input: "@JackhopkinsCEO")
        #expect(model.recentVideos.map(\.id) == ["v3", "v4", "v5"])

        model.dismissInbox(videoId: "v1")
        #expect(model.inbox.map(\.id) == ["v2"])
        #expect(model.recentVideos.map(\.id) == ["v1", "v3", "v4", "v5"])
        #expect(try store.loadState().recentVideos[info.id]?.count == 5)

        model.removeChannel(id: info.id)
        #expect(model.recentVideos.isEmpty)
    }

    @Test func moveChannelReordersAndPersists() async throws {
        let ids = ["UCa", "UCb", "UCc"]
        for id in ids {
            youtube.channels.withLock { $0[id] = ChannelInfo(id: id, title: id, handle: nil, avatarURL: nil) }
        }
        let model = makeModel()
        for id in ids { try await model.addChannel(input: id) }

        model.moveChannel(id: "UCc", before: "UCa")
        #expect(model.channels.map(\.id) == ["UCc", "UCa", "UCb"])
        model.moveChannel(id: "UCc", before: nil)
        #expect(model.channels.map(\.id) == ["UCa", "UCb", "UCc"])
        model.moveChannel(id: "UCa", before: "UCc")
        #expect(try store.loadSettings().channels.map(\.id) == ["UCb", "UCa", "UCc"])
    }

    @Test func checkFindsNewVideosAndNotifiesOnce() async throws {
        setUpChannel()
        let model = makeModel()
        try await model.addChannel(input: "@JackhopkinsCEO")
        youtube.publicFeeds.withLock { $0[info.id]!.insert(video("v0", channel: info.id, minutesAgo: 0), at: 0) }

        await model.checkNow()
        #expect(model.inbox.map(\.id) == ["v0", "v1", "v2"])
        #expect(notifier.newVideoBatches.map { $0.map(\.id) } == [["v0"]])
        #expect(model.lastCheck?.newVideos == 1)
        #expect(model.lastCheck?.isOK == true)
        #expect(model.log.contains { $0.message.contains("“Video v0”") })

        await model.checkNow()
        #expect(model.lastCheck?.newVideos == 0)
        #expect(notifier.newVideoBatches.count == 1)

        // A fresh model reads everything back from disk (dates are stored to the second).
        let reloaded = makeModel()
        #expect(reloaded.inbox.map(\.id) == model.inbox.map(\.id))
        #expect(reloaded.lastCheck?.trigger == .manual)
        #expect(reloaded.log.map(\.id) == model.log.map(\.id))
    }

    @Test func expiredCookiesAreReportedAndRecover() async throws {
        setUpChannel()
        account.state = .signedIn
        let model = makeModel()
        try await model.addChannel(input: "@JackhopkinsCEO")
        youtube.membersFeeds.withLock { $0[info.id] = .failure(.authExpired) }

        await model.checkNow()
        #expect(model.signInState == .expired)
        #expect(model.lastCheck?.isOK == false)
        #expect(notifier.problems == ["YouTube sign-in expired"])

        await model.checkNow()
        #expect(model.signInState == .expired)
        #expect(notifier.problems.count == 1)

        youtube.membersFeeds.withLock { $0[info.id] = .success(MembersFeed(videos: [video("m1", channel: info.id, members: true)])) }
        await model.checkNow()
        #expect(model.signInState == .signedIn)
        await model.memberAccessChecks?.value
        #expect(model.inbox.first?.id == "m1")
    }

    @Test func rejectedCookiesStillDeliverListedMembersVideos() async throws {
        setUpChannel()
        account.state = .signedIn
        let model = makeModel()
        try await model.addChannel(input: "@JackhopkinsCEO")
        youtube.membersFeeds.withLock {
            $0[info.id] = .success(MembersFeed(videos: [video("m1", channel: info.id, members: true)], cookiesRejected: true))
        }

        await model.checkNow()
        #expect(model.signInState == .expired)
        #expect(notifier.problems == ["YouTube sign-in expired"])
        // Kept, but hidden until a working sign-in shows the account can watch it.
        #expect(!model.inbox.contains { $0.id == "m1" })
        youtube.membersFeeds.withLock { $0[info.id] = .success(MembersFeed(videos: [video("m1", channel: info.id, members: true)])) }
        await model.checkNow()
        await model.memberAccessChecks?.value
        #expect(model.inbox.first?.id == "m1")
    }

    @Test func sessionEndedByYouTubeIsExpiredNotSignedOut() async throws {
        account.state = .signedIn
        let model = makeModel()
        await model.checkNow()
        #expect(model.signInState == .signedIn)

        account.state = .signedOut
        await model.checkNow()
        #expect(model.signInState == .expired)
        #expect(notifier.problems == ["YouTube sign-in expired"])

        // Closing the sign-in window without signing in changes nothing.
        account.signInSucceeds = false
        await model.signIn()
        #expect(model.signInState == .expired)

        account.signInSucceeds = true
        await model.signIn()
        #expect(model.signInState == .signedIn)

        await model.signOut()
        await model.checkNow()
        #expect(model.signInState == .signedOut)
        #expect(notifier.problems.count == 1)
    }

    @Test func newChannelSeedsTwoVideosAcrossBothFeeds() async throws {
        setUpChannel()
        account.state = .signedIn
        youtube.membersFeeds.withLock {
            $0[info.id] = .success(MembersFeed(videos: (1...3).map { video("m\($0)", channel: info.id, members: true) }))
        }
        let model = makeModel()
        await model.check(.launch)
        try await model.addChannel(input: "@JackhopkinsCEO")
        #expect(model.inbox.map(\.id) == ["v1", "v2"])

        // After an outage longer than a feed's window, every new video still arrives.
        youtube.publicFeeds.withLock { $0[info.id] = (1...15).map { video("n\($0)", channel: info.id, minutesAgo: Double($0)) } }
        await model.checkNow()
        #expect(model.lastCheck?.newVideos == 15)
    }

    @Test func repeatedFailuresNotifyOnceAndRecoveryIsLogged() async throws {
        setUpChannel()
        let model = makeModel()
        try await model.addChannel(input: "@JackhopkinsCEO")
        youtube.publicFeeds.withLock { $0[info.id] = nil }

        for _ in 1..<AppModel.failureNotifyStreak { await model.checkNow() }
        #expect(notifier.problems.isEmpty)
        await model.checkNow()
        #expect(notifier.problems == ["New-video checks are failing"])

        youtube.publicFeeds.withLock { $0[info.id] = [video("v1", channel: info.id)] }
        await model.checkNow()
        #expect(model.log.contains { $0.message == "Checks are working again." })
        #expect(try store.loadState().failedCheckStreak == 0)
    }

    @Test func failingFeedsAreErrorsNotCrashes() async throws {
        setUpChannel()
        account.state = .signedIn
        let model = makeModel()
        try await model.addChannel(input: "@JackhopkinsCEO")
        youtube.publicFeeds.withLock { $0[info.id] = nil }
        youtube.membersFeeds.withLock { $0[info.id] = .failure(.toolNotFound("yt-dlp")) }

        await model.checkNow()
        #expect(model.lastCheck?.errors.count == 2)
        #expect(notifier.problems == ["Members-only check is failing"])
        #expect(model.inbox.map(\.id) == ["v1", "v2"])
    }

    @Test func removeChannelForgetsItsVideos() async throws {
        setUpChannel()
        let model = makeModel()
        try await model.addChannel(input: "@JackhopkinsCEO")
        model.setMorning(false, channelId: info.id)
        #expect(try store.loadSettings().channels.first?.morning == false)

        model.removeChannel(id: info.id)
        #expect(model.channels.isEmpty)
        #expect(model.inbox.isEmpty)
        #expect(try store.loadState().seenVideoIds[info.id] == nil)
    }

    @Test func addSubscriptionsSkipsExistingChannels() async throws {
        setUpChannel()
        let other = ChannelInfo(id: "UCeUP5Kb-EDDplwAi0H02XlA", title: "TQQQCRAZY", handle: nil, avatarURL: nil)
        youtube.publicFeeds.withLock { $0[other.id] = [video("t1", channel: other.id)] }
        let model = makeModel()
        try await model.addChannel(input: "@JackhopkinsCEO")
        await model.addSubscriptions([info, other, other])
        #expect(model.channels.map(\.id) == [info.id, other.id])
        #expect(Set(model.inbox.map(\.id)) == ["v1", "v2", "t1"])
    }

    @Test func handEditedSettingsArePickedUp() async throws {
        let model = makeModel()
        try await Task.sleep(for: .milliseconds(10))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"channels": [{"id": "UCeUP5Kb-EDDplwAi0H02XlA"}], "futureKey": 1}"#.utf8).write(to: store.settingsFile)
        youtube.publicFeeds.withLock { $0["UCeUP5Kb-EDDplwAi0H02XlA"] = [video("a"), video("b"), video("c")] }

        await model.checkNow()
        #expect(model.channels.map(\.id) == ["UCeUP5Kb-EDDplwAi0H02XlA"])
        #expect(model.inbox.map(\.id) == ["a", "b"])
    }
}
