import Foundation
import Testing
@testable import Stow

struct WatchSyncTests {
    @Test func firstFetchIsAllNew() {
        #expect(WatchSync.newlyWatched(history: ["a", "b"], previous: []) == ["a", "b"])
    }

    @Test func entriesAboveThePreviousTopAreNew() {
        #expect(WatchSync.newlyWatched(history: ["x", "y", "a", "b"], previous: ["a", "b"]) == ["x", "y"])
        #expect(WatchSync.newlyWatched(history: ["a", "b"], previous: ["a", "b"]).isEmpty)
    }

    @Test func rewatchingAnOlderVideoCountsAsNew() {
        #expect(WatchSync.newlyWatched(history: ["c", "a", "b"], previous: ["a", "b", "c"]) == ["c"])
    }

    @Test func aDeletedTopEntryFallsBackToTheNextOne() {
        #expect(WatchSync.newlyWatched(history: ["x", "b", "c"], previous: ["a", "b", "c"]) == ["x"])
    }

    @Test func parsesHistoryWithoutRepeats() throws {
        let json = #"{"id": "history", "entries": [{"id": "v1", "title": "One"}, null, {"id": "v2"}, {"id": "v1"}]}"#
        #expect(try WatchHistoryClient.parse(historyJSON: Data(json.utf8)) == ["v1", "v2"])
        #expect(try WatchHistoryClient.parse(historyJSON: Data("null".utf8)).isEmpty)
        #expect(throws: StowError.self) { try WatchHistoryClient.parse(historyJSON: Data("<html>".utf8)) }
    }
}

@MainActor
struct WatchedSyncModelTests {
    let youtube = FakeYouTube()
    let account = FakeAccount()
    let store = Store(directory: temporaryDirectory())
    let channelId = "UCwatch"

    /// Signed in, one channel with v1…v5 (v1, v2 in New).
    func makeModel() async throws -> AppModel {
        youtube.channels.withLock { $0["@w"] = ChannelInfo(id: channelId, title: "W", handle: nil, avatarURL: nil) }
        youtube.publicFeeds.withLock { $0[channelId] = (1...5).map { video("v\($0)", channel: channelId, minutesAgo: Double($0)) } }
        account.state = .signedIn
        let model = AppModel(youtube: youtube, account: account, store: store, notifier: FakeNotifier(),
                             cookiesFile: store.directory.appending(path: "cookies.txt"))
        model.load()
        await model.check(.launch)
        try await model.addChannel(input: "@w")
        return model
    }

    @Test func watchedOnYouTubeBecomesWatchedHere() async throws {
        let model = try await makeModel()
        youtube.history.withLock { $0 = .success(["v1", "other", "v4"]) }
        await model.syncWatched()
        #expect(model.isWatched(videoId: "v1") && model.isWatched(videoId: "v4"))
        #expect(!model.isWatched(videoId: "other"))
        #expect(model.inbox.map(\.id) == ["v2"])
        #expect(model.lastWatchSync != nil && model.watchSyncError == nil)

        // Unwatched in Stow stays unwatched until it's watched on YouTube again.
        model.setWatched(false, videoId: "v4")
        await model.syncWatched()
        #expect(!model.isWatched(videoId: "v4"))
        youtube.history.withLock { $0 = .success(["v4", "v1", "other"]) }
        await model.syncWatched()
        #expect(model.isWatched(videoId: "v4"))
        #expect(youtube.markedWatched.withLock { $0 }.isEmpty)
    }

    @Test func markedWatchedHereIsSentToYouTube() async throws {
        let model = try await makeModel()
        model.setWatched(true, videoId: "v2")
        #expect(model.inbox.map(\.id) == ["v1"])
        await model.syncWatched()
        #expect(youtube.markedWatched.withLock { $0 } == ["v2"])
        #expect(try store.loadState().pendingYouTubeWatched.isEmpty)
        #expect(model.isWatched(videoId: "v2"))
    }

    @Test func failedMarksStayQueued() async throws {
        let model = try await makeModel()
        youtube.markWatchedError.withLock { $0 = .network("offline") }
        model.setWatched(true, videoId: "v3")
        await model.syncWatched()
        #expect(try store.loadState().pendingYouTubeWatched == ["v3"])
        #expect(model.watchSyncError != nil)

        youtube.markWatchedError.withLock { $0 = nil }
        await model.syncWatched()
        #expect(youtube.markedWatched.withLock { $0 } == ["v3"])
        #expect(model.watchSyncError == nil)
    }

    @Test func videoWatchedBeforeStowFoundItSkipsNew() async throws {
        let model = try await makeModel()
        await model.syncWatched()
        youtube.history.withLock { $0 = .success(["v0"]) }
        await model.syncWatched()
        youtube.publicFeeds.withLock { $0[channelId] = [video("v0", channel: channelId, minutesAgo: 0)] + $0[channelId]! }
        await model.check(.manual)
        #expect(!model.inbox.contains { $0.id == "v0" })
        #expect(model.isWatched(videoId: "v0"))
        #expect(model.recentVideos(channelId: channelId).first?.id == "v0")
    }

    @Test func syncOffOrSignedOutDoesNothing() async throws {
        let model = try await makeModel()
        model.setSyncWatchedWithYouTube(false)
        youtube.history.withLock { $0 = .success(["v1"]) }
        model.setWatched(true, videoId: "v2")
        await model.syncWatched()
        #expect(!model.isWatched(videoId: "v1"))
        #expect(youtube.markedWatched.withLock { $0 }.isEmpty)
        #expect(try store.loadSettings().syncWatchedWithYouTube == false)
    }
}
