import Foundation
import Testing
@testable import StowKit

@MainActor
@Suite struct RepositoryMergeTests {
    private func video(_ id: String, channel: String = "UCa", days: Double? = nil, seconds: Int? = nil) -> Video {
        Video(id: id, channelId: channel, channelTitle: channel, title: id,
              publishedAt: days.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * 86_400) },
              thumbnailURL: nil, isMembersOnly: false, durationSeconds: seconds)
    }

    @Test func laterSourcesWinAndFeedsLendTheirLengths() {
        let feeds = YouTubeFeeds(recommended: [video("rec00000001", seconds: 300), video("both0000001", seconds: 600)],
                                 subscriptions: [video("sub00000001", seconds: 400), video("rec00000001", seconds: 300)])
        let channels = [Channel(id: "UCa", title: "A", handle: nil, avatarURL: nil, order: 0, recent: [
            RecentVideo(video: video("both0000001", days: 1), watched: true),
            RecentVideo(video: video("chan0000001", days: 2), watched: false),
        ])]
        let sent = [SentVideo(video: video("both0000001", days: 1), sentAt: Date(timeIntervalSince1970: 1_800_000_000), sentBy: "mac", watched: false),
                    SentVideo(video: video("sentonly001", days: 3), sentAt: nil, sentBy: "phone", watched: true)]
        let local = ["chan0000001": LocalVideo(id: "chan0000001", state: .downloaded, fileName: "chan0000001.mp4")]
        let merged = Repository.mergeItems(sent: sent, channels: channels, local: local, watchedHere: ["sub00000001"],
                                           feeds: feeds, searched: [video("found000001"), video("rec00000001")])
        #expect(merged.order == ["rec00000001", "both0000001", "sub00000001", "found000001", "chan0000001", "sentonly001"])
        let items = merged.items
        #expect(items["rec00000001"]?.onlyInYouTubeFeeds == true)
        #expect(items["rec00000001"]?.fromSearch == false)
        #expect(items["found000001"]?.fromSearch == true && items["found000001"]?.onlyInYouTubeFeeds == true)
        #expect(items["sub00000001"]?.watched == true)
        // The Mac's channel and then its sent video take over the feed's copy, keeping its length.
        let both = items["both0000001"]
        #expect(both?.onlyInYouTubeFeeds == false)
        #expect(both?.sent?.sentBy == "mac")
        #expect(both?.video.durationSeconds == 600)
        #expect(both?.watchedOnMac == true)
        // Sent says it isn't watched: that wins.
        #expect(both?.watched == false)
        #expect(items["chan0000001"]?.isPlayable == true)
        #expect(items["sentonly001"]?.watched == true)
    }

    @Test func shortsGoUnlessDownloaded() {
        let feeds = YouTubeFeeds(recommended: [video("short000001", seconds: 30), video("short000002", seconds: 45)])
        let local = ["short000002": LocalVideo(id: "short000002", state: .downloaded, fileName: "short000002.mp4")]
        let merged = Repository.mergeItems(sent: [], channels: [], local: local, watchedHere: [], feeds: feeds, searched: [])
        #expect(merged.order == ["short000002"])
        #expect(Set(merged.items.keys) == ["short000002"])
    }
}

@MainActor
@Suite struct RepositoryDemoTests {
    private func makeDemo(youtube: FakeYouTube = FakeYouTube(), network: FixedNetwork = FixedNetwork(.wifi)) -> (Repository, FakeYouTube) {
        let repository = Repository(config: nil, youtube: youtube, demo: true, defaults: freshDefaults(), directory: temporaryDirectory(),
                                    tokenStore: InMemoryTokenStore(), network: network)
        return (repository, youtube)
    }

    @Test func showsTheSamplesAndDownloadsWhatWasSent() async throws {
        let (repository, youtube) = makeDemo()
        #expect(repository.isPaired)
        #expect(repository.remote == nil)
        repository.start()
        #expect(repository.channels.map(\.title) == ["jawed", "Rick Astley"])
        #expect(repository.recommended.map(\.id) == ["9bZkp7q19f0", "kJQP7kiw5Fk", "JGwWNGJdvx8"])
        // Home's list leaves out what's only in YouTube's feeds; Subscriptions mixes both.
        #expect(!repository.feed.contains { $0.onlyInYouTubeFeeds })
        #expect(repository.feed.first?.id == "jNQXAC9IVRw")
        #expect(repository.subscriptionsFeed.map(\.id).contains("OPf0YbXqDm0"))
        // Rick's "Together Forever" is in the channel and the feed: the channel's copy, with the feed's length.
        #expect(repository.item("yPYZpwSpKmA")?.onlyInYouTubeFeeds == false)
        #expect(repository.item("yPYZpwSpKmA")?.video.durationSeconds == 211)
        #expect(repository.item("yPYZpwSpKmA")?.watched == true)
        #expect(repository.subscribedChannels.map(\.id).contains("UCdKDCoP9NM48pyhcKeVB7cQ"))
        #expect(repository.knownChannels.first?.id == "UC4QobU6STFB0P71PMvOGN5A")

        // The sent video downloads right away.
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.isPlayable == true })
        #expect(youtube.downloadCalls == ["jNQXAC9IVRw"])
        let file = try #require(repository.fileURL(for: "jNQXAC9IVRw"))
        #expect(file.deletingLastPathComponent().lastPathComponent == "Downloads")
        #expect(repository.local["jNQXAC9IVRw"]?.progress == 100)
        #expect(repository.local["jNQXAC9IVRw"]?.sizeBytes ?? 0 > 0)
        #expect(repository.downloadIds() == ["jNQXAC9IVRw"])

        repository.deleteDownload("jNQXAC9IVRw")
        #expect(repository.item("jNQXAC9IVRw")?.state == nil)
        #expect(repository.fileURL(for: "jNQXAC9IVRw") == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func downloadingAFeedVideoSendsIt() async {
        let (repository, youtube) = makeDemo()
        repository.start()
        _ = await eventually { repository.downloads.activeId == nil && repository.downloads.queuedIds.isEmpty }
        let item = try! #require(repository.item("9bZkp7q19f0"))
        #expect(item.sent == nil)
        repository.download(item)
        #expect(repository.item("9bZkp7q19f0")?.sent?.sentBy == "phone")
        #expect(repository.item("9bZkp7q19f0")?.onlyInYouTubeFeeds == false)
        #expect(repository.feed.contains { $0.id == "9bZkp7q19f0" })
        #expect(await eventually { repository.item("9bZkp7q19f0")?.isPlayable == true })
        #expect(youtube.downloadCalls.contains("9bZkp7q19f0"))
        // Already downloaded: nothing more to do.
        repository.download(repository.item("9bZkp7q19f0")!)
        #expect(youtube.downloadCalls.filter { $0 == "9bZkp7q19f0" }.count == 1)
    }

    @Test func watchedHereOrOnTheMac() {
        let (repository, _) = makeDemo()
        repository.start()
        // Never sent: remembered on the phone.
        repository.setWatched("kJQP7kiw5Fk", true)
        #expect(repository.item("kJQP7kiw5Fk")?.watched == true)
        #expect(repository.prefs.watchedHere.contains("kJQP7kiw5Fk"))
        // Sent: changes the sent video (in demo mode, locally).
        repository.setWatched("jNQXAC9IVRw", true)
        #expect(repository.item("jNQXAC9IVRw")?.watched == true)
        #expect(repository.item("jNQXAC9IVRw")?.progress == 1)
        #expect(repository.stats.today().finished == 2)
        repository.setWatched("jNQXAC9IVRw", false)
        #expect(repository.item("jNQXAC9IVRw")?.watched == false)
    }

    @Test func searchResultsStayOutOfTheOtherLists() async throws {
        let youtube = FakeYouTube()
        youtube.searchJSON = #"{"entries":[{"id":"n61ULEU7CO0","title":"Best of lofi","channel":"Lofi Girl","channel_id":"UCSJ4gkVC6NrvII8umztf0Ow","duration":22258}]}"#
        let (repository, _) = makeDemo(youtube: youtube)
        repository.start()
        #expect(try await repository.searchYouTube("lofi") == ["n61ULEU7CO0"])
        #expect(repository.prefs.recentSearches == ["lofi"])
        #expect(repository.item("n61ULEU7CO0")?.fromSearch == true)
        #expect(!repository.everything.contains { $0.id == "n61ULEU7CO0" })
        #expect(!repository.feed.contains { $0.id == "n61ULEU7CO0" })
        #expect(repository.channelVideos("UCSJ4gkVC6NrvII8umztf0Ow").map(\.id) == ["n61ULEU7CO0"])
    }

    @Test func channelPagesLoadOnceInHalfAnHour() async throws {
        let youtube = FakeYouTube()
        youtube.channelJSON["UCOxqgCwgOqC2lMqC5PYz_Dg/videos"] = """
            {"channel":"Chillhop Music","channel_id":"UCOxqgCwgOqC2lMqC5PYz_Dg",
             "thumbnails":[{"url":"https://yt3.example/avatar","id":"avatar_uncropped"}],
             "entries":[{"id":"AodSJJ-ZvuI","title":"Chillhop Sanctuary","duration":7249},{"id":"shortshort1","duration":20}]}
            """
        youtube.channelJSON["UCOxqgCwgOqC2lMqC5PYz_Dg/streams"] = """
            {"channel":"Chillhop Music","channel_id":"UCOxqgCwgOqC2lMqC5PYz_Dg",
             "entries":[{"id":"stream00001","title":"Live radio","live_status":"is_live"},{"id":"stream00002","title":"Last week","live_status":"was_live","duration":9000}]}
            """
        let (repository, _) = makeDemo(youtube: youtube)
        repository.start()
        try await repository.loadChannelPage("UCOxqgCwgOqC2lMqC5PYz_Dg")
        let page = try #require(repository.channelPages["UCOxqgCwgOqC2lMqC5PYz_Dg"])
        #expect(page.title == "Chillhop Music")
        #expect(page.avatarURL == "https://yt3.example/avatar")
        #expect(page.videoIds == ["AodSJJ-ZvuI"])
        #expect(page.streamIds == ["stream00002"])
        #expect(repository.channelVideos("UCOxqgCwgOqC2lMqC5PYz_Dg").map(\.id) == ["AodSJJ-ZvuI", "stream00002"])
        #expect(repository.avatars["UCOxqgCwgOqC2lMqC5PYz_Dg"] == "https://yt3.example/avatar")
        #expect(repository.channelTitle("UCOxqgCwgOqC2lMqC5PYz_Dg") == "Chillhop Music")
        // A channel without live streams still loads its videos.
        youtube.channelJSON["UCOxqgCwgOqC2lMqC5PYz_Dg/streams"] = nil
        youtube.channelJSON["UCnostreams/videos"] = #"{"channel":"Quiet","channel_id":"UCnostreams","entries":[{"id":"quiet000001","title":"Q","duration":600}]}"#
        try await repository.loadChannelPage("UCnostreams")
        #expect(repository.channelPages["UCnostreams"]?.streamIds == [])
    }

    @Test func groupsEditLocallyInDemoMode() {
        let (repository, _) = makeDemo()
        repository.start()
        let music = repository.createGroup(" Music ", with: GroupChannel(id: "UCuAXFkgsw1L7xaCfnd5JJOw", title: "Rick Astley"))
        let other = repository.createGroup("Other")
        #expect(repository.groups.map(\.name) == ["Music", "Other"])
        repository.moveGroup(other.id, by: -1)
        #expect(repository.groups.map(\.id) == [other.id, music.id])
        repository.setInGroup(other.id, channel: GroupChannel(id: "UC4QobU6STFB0P71PMvOGN5A", title: "jawed"), included: true)
        repository.renameGroup(other.id, to: "Firsts")
        #expect(repository.groups.first?.name == "Firsts")
        #expect(repository.groupVideos(repository.groups[0]).map(\.id) == ["jNQXAC9IVRw"])
        #expect(repository.groupVideos(repository.groups[1]).first?.video.channelId == "UCuAXFkgsw1L7xaCfnd5JJOw")
        repository.deleteGroup(other.id)
        #expect(repository.groups.map(\.id) == [music.id])
    }

    @Test func pullToRefreshAnswersInDemoMode() async {
        let (repository, _) = makeDemo()
        repository.start()
        #expect(await repository.refreshFromMac() == .done)
    }

    @Test func commentsAreSavedForOffline() async throws {
        let youtube = FakeYouTube()
        youtube.commentsJSON = #"{"formats":[1],"comment_count":2,"comments":[{"id":"a","parent":"root","text":"Hi","author":"@a"}]}"#
        let (repository, _) = makeDemo(youtube: youtube)
        let video = DemoData.sent()[0].video
        #expect(try await repository.comments(video).threads.map(\.text) == ["Hi"])
        youtube.commentsJSON = #"{"comments":[]}"#
        // The saved copy, unless asked for fresh ones.
        #expect(try await repository.comments(video).threads.count == 1)
        #expect(try await repository.comments(video, fresh: true).threads.isEmpty)
    }
}

@MainActor
@Suite struct DownloadManagerTests {
    private func makeDemo(_ youtube: FakeYouTube, network: FixedNetwork) -> Repository {
        let repository = Repository(config: nil, youtube: youtube, demo: true, defaults: freshDefaults(), directory: temporaryDirectory(),
                                    tokenStore: InMemoryTokenStore(), network: network)
        repository.downloads.retryDelay = { _ in 0 }
        return repository
    }

    @Test func retriesThreeTimesThenFails() async {
        let youtube = FakeYouTube()
        youtube.failures = 10
        let repository = makeDemo(youtube, network: FixedNetwork(.wifi))
        repository.start()
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.state == .failed })
        #expect(youtube.downloadCalls.count == 4)
        #expect(repository.item("jNQXAC9IVRw")?.local?.error == "ERROR: HTTP Error 403: Forbidden")
        #expect(repository.downloads.queuedIds.isEmpty)
        // Retrying asks again from scratch.
        youtube.failures = 0
        repository.retry("jNQXAC9IVRw")
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.isPlayable == true })
        #expect(repository.item("jNQXAC9IVRw")?.local?.error == nil)
    }

    @Test func aFailureThatRecoversDownloads() async {
        let youtube = FakeYouTube()
        youtube.failures = 2
        let repository = makeDemo(youtube, network: FixedNetwork(.wifi))
        repository.start()
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.isPlayable == true })
        #expect(youtube.downloadCalls.count == 3)
    }

    @Test func waitsForWiFiUnlessAllowed() async {
        let youtube = FakeYouTube()
        let network = FixedNetwork(.cellular)
        let repository = makeDemo(youtube, network: network)
        repository.start()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(youtube.downloadCalls.isEmpty)
        #expect(repository.item("jNQXAC9IVRw")?.state == .queued)
        #expect(repository.downloads.isWaitingForNetwork)
        network.status = .wifi
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.isPlayable == true })

        // Mobile data allowed: goes right away.
        let other = makeDemo(FakeYouTube(), network: FixedNetwork(.cellular))
        other.setWifiOnly(false)
        other.start()
        #expect(await eventually { other.item("jNQXAC9IVRw")?.isPlayable == true })
    }

    @Test func leavingWiFiPausesAndComesBack() async {
        let youtube = FakeYouTube()
        youtube.holdDownloads = true
        let network = FixedNetwork(.wifi)
        let repository = makeDemo(youtube, network: network)
        repository.start()
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.state == .downloading })
        #expect(await eventually { repository.local["jNQXAC9IVRw"]?.progress == 50 })
        network.status = .cellular
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.state == .queued })
        #expect(youtube.cancelCalls == ["jNQXAC9IVRw"])
        // Paused isn't failed: no error, and it resumes.
        #expect(repository.item("jNQXAC9IVRw")?.local?.error == nil)
        youtube.release()
        network.status = .wifi
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.isPlayable == true })
        #expect(youtube.downloadCalls == ["jNQXAC9IVRw", "jNQXAC9IVRw"])
    }

    @Test func deletingStopsADownload() async {
        let youtube = FakeYouTube()
        youtube.holdDownloads = true
        let repository = makeDemo(youtube, network: FixedNetwork(.wifi))
        repository.start()
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.state == .downloading })
        repository.deleteDownload("jNQXAC9IVRw")
        #expect(await eventually { repository.downloads.activeId == nil })
        #expect(repository.local["jNQXAC9IVRw"]?.state == .deleted)
        #expect(repository.downloads.queuedIds.isEmpty)
        youtube.release()
    }

    @Test func suspendingStopsUntilResumed() async {
        let youtube = FakeYouTube()
        youtube.holdDownloads = true
        let repository = makeDemo(youtube, network: FixedNetwork(.wifi))
        repository.start()
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.state == .downloading })
        let parts = repository.local.partsDirectory(for: "jNQXAC9IVRw")
        try? FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        repository.downloads.suspend()
        #expect(repository.downloads.hold == .suspended)
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.state == .queued })
        // Not a failure, and what was downloaded stays for the next try.
        #expect(repository.item("jNQXAC9IVRw")?.local?.error == nil)
        #expect(FileManager.default.fileExists(atPath: parts.path))
        youtube.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(youtube.downloadCalls.count == 1)
        repository.downloads.resume()
        #expect(repository.downloads.hold == .none)
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.isPlayable == true })
    }

    @Test func deletingDropsThePartialDownload() async {
        let youtube = FakeYouTube()
        youtube.holdDownloads = true
        let repository = makeDemo(youtube, network: FixedNetwork(.wifi))
        repository.start()
        #expect(await eventually { repository.item("jNQXAC9IVRw")?.state == .downloading })
        let parts = repository.local.partsDirectory(for: "jNQXAC9IVRw")
        try? FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        repository.deleteDownload("jNQXAC9IVRw")
        // The tool may still write until it notices: the folder goes again once it has stopped.
        try? FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        youtube.release()
        #expect(await eventually { repository.downloads.activeId == nil })
        #expect(!FileManager.default.fileExists(atPath: parts.path))
    }

    @Test func saysWhyDownloadsWait() async {
        let network = FixedNetwork(.offline)
        let repository = makeDemo(FakeYouTube(), network: network)
        #expect(repository.downloads.hold == .noConnection)
        network.status = .cellular
        #expect(repository.downloads.hold == .waitingForWiFi)
        repository.setWifiOnly(false)
        #expect(repository.downloads.hold == .none)
    }

    @Test func theQueueSurvivesARelaunch() async {
        let directory = temporaryDirectory()
        let defaults = freshDefaults()
        let youtube = FakeYouTube()
        let first = Repository(config: nil, youtube: youtube, demo: true, defaults: defaults, directory: directory,
                               tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline))
        first.start()
        #expect(first.downloads.queuedIds == ["jNQXAC9IVRw"])
        let again = Repository(config: nil, youtube: youtube, demo: true, defaults: defaults, directory: directory,
                               tokenStore: InMemoryTokenStore(), network: FixedNetwork(.wifi))
        #expect(again.downloads.queuedIds == ["jNQXAC9IVRw"])
        again.start()
        #expect(await eventually { again.item("jNQXAC9IVRw")?.isPlayable == true })
    }
}

/// The repository against a stubbed Firebase: polling, merging and being unpaired.
@MainActor
@Suite struct RepositoryLiveTests {
    private let key = Data((0..<32).map { UInt8($0 * 3) })

    private func paired(_ server: StubServer, tokens: InMemoryTokenStore = InMemoryTokenStore(validTokens())) -> Repository {
        let defaults = freshDefaults()
        defaults.set("stow-test", forKey: "pairedProject")
        defaults.set(key.base64URLEncodedString, forKey: "pairingKey")
        return Repository(config: testConfig, youtube: FakeYouTube(), defaults: defaults, directory: temporaryDirectory(),
                          tokenStore: tokens, network: FixedNetwork(.offline), session: server.session)
    }

    @Test func pollsEverythingAndMerges() async throws {
        let feeds = #"{"recommended":[{"id":"9bZkp7q19f0","channelId":"UCpsy","channelTitle":"officialpsy","title":"Gangnam Style","duration":252}],"subscriptions":[]}"#
        let sealed = try SealHelper.seal(Data(feeds.utf8), key: key).base64EncodedString()
        let server = StubServer { request in
            switch request.path {
            case "\(documentsPrefix)/videos": return (200, try! fixture("videos-list.json"))
            case "\(documentsPrefix)/channels": return (200, try! fixture("channels-list.json"))
            case "\(documentsPrefix)/shared/phone": return (200, try! fixture("shared-phone.json"))
            case "\(documentsPrefix)/secrets/feeds":
                return (200, #"{"name":"projects/stow-test/databases/(default)/documents/secrets/feeds","fields":{"sealed":{"stringValue":"\#(sealed)"}}}"#)
            case "\(documentsPrefix):commit": return (200, #"{"writeResults":[{}]}"#)
            case "\(documentsPrefix):runQuery":
                // Later polls ask only for what changed since the newest updatedAt seen.
                let query = request.json["structuredQuery"] as? [String: Any]
                let from = (query?["from"] as? [[String: Any]])?.first?["collectionId"] as? String
                let filter = (query?["where"] as? [String: Any])?["fieldFilter"] as? [String: Any]
                let after = (filter?["value"] as? [String: Any])?["timestampValue"] as? String
                #expect(filter?["op"] as? String == "GREATER_THAN")
                if from == "videos" {
                    #expect(after == "2026-11-21T07:00:00Z")
                    return (200, """
                        [{"document":{"name":"projects/stow-test/databases/(default)/documents/videos/AodSJJ-ZvuI","fields":{
                          "title":{"stringValue":"Sent just now"},"channelId":{"stringValue":"UCOx"},"sentAt":{"timestampValue":"2026-11-27T09:00:00Z"},
                          "updatedAt":{"timestampValue":"2026-11-27T09:00:00.5Z"}}},"readTime":"2026-11-27T09:00:01Z"}]
                        """)
                }
                #expect(from == "channels")
                #expect(after == "2026-11-20T07:00:00Z")
                return (200, #"[{"readTime":"2026-11-27T09:00:01Z"}]"#)
            default: return (404, #"{"error":{"code":404,"status":"NOT_FOUND"}}"#)
            }
        }
        let repository = paired(server)
        #expect(repository.isPaired)
        #expect(await repository.refresh())
        #expect(repository.lastSync != nil && repository.syncError == nil)
        #expect(repository.channels.map(\.title) == ["jawed", "Rick Astley"])
        #expect(repository.groups.map(\.name) == ["Music", "Group"])
        #expect(repository.recommended.map(\.id) == ["9bZkp7q19f0"])
        let rick = try #require(repository.item("dQw4w9WgXcQ"))
        #expect(rick.sent?.sentBy == "morning")
        #expect(rick.watched)
        // Sent videos queue for download (offline here, so they wait).
        #expect(repository.item("lYBUbBu4W08")?.state == .queued)
        #expect(Set(repository.downloads.queuedIds) == ["dQw4w9WgXcQ", "lYBUbBu4W08"])

        // Marked unwatched on the phone: shows at once, and the next poll (still the old value) doesn't undo it.
        repository.setWatched("dQw4w9WgXcQ", false)
        #expect(repository.item("dQw4w9WgXcQ")?.watched == false)
        #expect(await eventually { server.requests.contains { $0.path.hasSuffix(":commit") } })
        #expect(await repository.refresh())
        #expect(repository.item("dQw4w9WgXcQ")?.watched == false)
        // The incremental poll added the new video and kept the others.
        #expect(repository.item("AodSJJ-ZvuI")?.sent != nil)
        #expect(repository.item("lYBUbBu4W08")?.sent != nil)
        #expect(repository.channels.count == 2)
        #expect(server.requests.filter { $0.path == "\(documentsPrefix)/videos" }.count == 1)
        let commit = try #require(server.requests.first { $0.path.hasSuffix(":commit") })
        let update = (commit.json["writes"] as? [[String: Any]])?.first?["update"] as? [String: Any]
        #expect((update?["name"] as? String)?.hasSuffix("/videos/dQw4w9WgXcQ") == true)
        // Never the Android phone's download state.
        #expect((update?["fields"] as? [String: Any])?["phone"] == nil)
    }

    @Test func refusedReadsUnpairOnlyWhenTheMacDroppedThePhone() async {
        let server = StubServer { _ in (403, try! fixture("permission-denied.json")) }
        let repository = paired(server)
        #expect(await repository.refresh() == false)
        #expect(repository.pairState == .unpaired(message: "The Mac unpaired this phone."))
        #expect(repository.prefs.pairingKey == nil)

        // Refused but still a member (a hiccup): stays paired.
        let flaky = StubServer { request in
            if request.path == "\(documentsPrefix)/members/phone-uid" {
                return (200, #"{"name":"projects/stow-test/databases/(default)/documents/members/phone-uid","fields":{}}"#)
            }
            return (403, try! fixture("permission-denied.json"))
        }
        let stillPaired = paired(flaky)
        #expect(await stillPaired.refresh() == false)
        #expect(stillPaired.isPaired)
    }

    @Test func networkTroubleKeepsWhatWasThere() async {
        let server = StubServer { _ in (503, #"{"error":{"code":503,"message":"Unavailable","status":"UNAVAILABLE"}}"#) }
        let repository = paired(server)
        #expect(await repository.refresh() == false)
        #expect(repository.isPaired)
        #expect(repository.syncError?.contains("503") == true)
    }

    @Test func pairingFromTheQRCode() async {
        let server = StubServer { request in
            switch request.path {
            case "/v1/accounts:signUp": return (200, #"{"idToken":"id-token-1","refreshToken":"refresh-1","expiresIn":"3600","localId":"phone-uid"}"#)
            case "\(documentsPrefix):commit": return (200, #"{"writeResults":[{}]}"#)
            case "\(documentsPrefix)/members/phone-uid": return (200, #"{"name":"projects/stow-test/databases/(default)/documents/members/phone-uid","fields":{}}"#)
            case "\(documentsPrefix)/videos", "\(documentsPrefix)/channels": return (200, "{}")
            default: return (404, #"{"error":{"code":404,"status":"NOT_FOUND"}}"#)
            }
        }
        let repository = Repository(config: testConfig, youtube: FakeYouTube(), defaults: freshDefaults(), directory: temporaryDirectory(),
                                    tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline), session: server.session)
        #expect(repository.pairState == .unpaired(message: nil))
        await repository.pair("not a code")
        #expect(repository.pairState == .unpaired(message: "That isn't a Stow pairing code. Open Stow › Phone › Pair a Phone on the Mac."))
        let code = String(repeating: "c", count: 43)
        await repository.pair("stow://pair?p=stow-test&c=\(code)&k=\(key.base64URLEncodedString)")
        #expect(repository.pairState == .paired)
        #expect(repository.prefs.pairingKey == key)
        #expect(repository.prefs.pairedProject == "stow-test")
        #expect(repository.lastSync != nil)

        repository.unpair()
        #expect(repository.pairState == .unpaired(message: nil))
        #expect(repository.items.isEmpty)
    }

    @Test func withoutFirebaseSettingsPairingSaysSo() async {
        let repository = Repository(config: nil, youtube: FakeYouTube(), defaults: freshDefaults(), directory: temporaryDirectory(),
                                    tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline))
        await repository.pair("stow://pair?p=x&c=\(String(repeating: "y", count: 32))&k=z")
        #expect(repository.pairState == .unpaired(message: StowError.notConfigured.message))
    }
}
