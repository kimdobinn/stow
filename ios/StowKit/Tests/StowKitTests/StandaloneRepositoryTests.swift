import Foundation
import Testing
@testable import StowKit

/// The Repository in standalone mode, end to end: a fake yt-dlp and a stubbed youtube.com, with
/// Firebase's hosts on the same stub as a tripwire (none may ever be asked).
@MainActor
@Suite struct StandaloneRepositoryTests {
    static let channelId = "UCtestchannel00000000001"
    static let streamsURL = "https://www.youtube.com/channel/\(channelId)/streams"
    static let streamsJSON = #"""
    {"channel":"Test Channel","entries":[
      {"id":"str00000001","title":"Launch replay","live_status":"was_live","duration":5400,"timestamp":1795000000},
      {"id":"str00000002","title":"Live now","live_status":"is_live"}
    ]}
    """#

    /// youtube.com answers from the fixtures; anything else is a 404.
    static func youtubeServer(extra: ((StubServer.Request) -> (Int, String)?)? = nil) throws -> StubServer {
        let rss = try fixture("rss-uploads.xml")
        let page = try fixture("channel-page.html")
        return StubServer { request in
            if let answer = extra?(request) { return answer }
            if firebaseHosts.contains(request.url.host() ?? "") { return (500, "{}") }
            switch request.path {
            case "/feeds/videos.xml":
                if request.query["playlist_id"] == ["UULFtestchannel00000000001"] { return (200, rss) }
                return (404, "")
            case "/@TestChannel", "/channel/\(channelId)": return (200, page)
            case "/watch": return (200, #"{"videoDetails":{"channelId":"\#(channelId)"}}"#)
            default: return (404, "")
            }
        }
    }

    struct Setup {
        let repository: Repository
        let youtube: FakeYouTube
        let server: StubServer
        let vault: InMemoryCookieVault
        let directory: URL
        let defaults: UserDefaults
    }

    static func make(server: StubServer? = nil, defaults: UserDefaults = freshDefaults(), directory: URL = temporaryDirectory(),
                     vault: InMemoryCookieVault = InMemoryCookieVault(), tokens: InMemoryTokenStore = InMemoryTokenStore()) throws -> Setup {
        let server = try server ?? youtubeServer()
        let youtube = FakeYouTube()
        youtube.flat[streamsURL] = streamsJSON
        let repository = Repository(config: testConfig, youtube: youtube, defaults: defaults, directory: directory,
                                    tokenStore: tokens, network: FixedNetwork(.offline), session: server.session,
                                    cookieVault: vault, webSession: server.session)
        return Setup(repository: repository, youtube: youtube, server: server, vault: vault, directory: directory, defaults: defaults)
    }

    @Test func aFreshInstallChoosesThenRunsOnItsOwn() async throws {
        let setup = try Self.make()
        let repository = setup.repository
        #expect(repository.mode == .choosing)
        #expect(repository.remote == nil)
        repository.chooseStandalone()
        #expect(repository.mode == .standalone)
        #expect(repository.prefs.appMode == "standalone")
        #expect(repository.remote == nil)
        #expect(!repository.firebaseGuard.isOpen)
        #expect(repository.standalone != nil)
        repository.start()
        // Nothing followed: the check finds nothing, and Home falls back to "everything" (empty).
        #expect(await eventually { repository.standalone?.state.lastCheck != nil })
        #expect(repository.everything.isEmpty)
        #expect(setup.server.firebaseRequests.isEmpty)
    }

    @Test func followingSeedsTheChannel() async throws {
        let setup = try Self.make()
        let repository = setup.repository
        repository.chooseStandalone()
        let engine = try #require(repository.standalone)
        let added = try await engine.addChannel(input: "@TestChannel")
        #expect(added.id == Self.channelId)
        #expect(added.title == "Test & Channel")
        #expect(added.handle == "@TestChannel")
        #expect(repository.followedIds == [Self.channelId])
        #expect(await eventually { repository.channel(Self.channelId)?.recent.count == 3 })
        let recent = try #require(repository.channel(Self.channelId)?.recent.map(\.video))
        // The channel's own name, uploads and the finished stream (not the live one), newest first.
        #expect(recent.map(\.id) == ["vid00000001", "str00000001", "vid00000002"])
        #expect(recent.allSatisfy { $0.channelTitle == "Test & Channel" })
        #expect(recent[1].isPastStream)
        #expect(!recent.contains { $0.id == "str00000002" })
        #expect(repository.everything.map(\.id).contains("vid00000001"))
        #expect(repository.subscribedChannels.map(\.id) == [Self.channelId])
        #expect(engine.state.fetchedAt[Self.channelId]?.uploads != nil)
        #expect(engine.state.fetchedAt[Self.channelId]?.streams != nil)

        // The same channel by another form, and inputs that aren't channels.
        await #expect(throws: StandaloneError.alreadyAdded("Test & Channel")) {
            _ = try await engine.addChannel(input: "https://www.youtube.com/channel/\(Self.channelId)")
        }
        await #expect(throws: StandaloneError.alreadyAdded("Test & Channel")) {
            _ = try await engine.addChannel(input: "https://www.youtube.com/watch?v=vid00000001")
        }
        await #expect(throws: StandaloneError.notFound("@thishandledoesnotexist12345")) {
            _ = try await engine.addChannel(input: "@thishandledoesnotexist12345")
        }
        await #expect(throws: StandaloneError.invalidInput("not a channel!!")) {
            _ = try await engine.addChannel(input: "not a channel!!")
        }
        // Kept across launches.
        let again = try Self.make(server: setup.server, defaults: setup.defaults, directory: setup.directory, vault: setup.vault)
        #expect(again.repository.mode == .standalone)
        #expect(again.repository.channel(Self.channelId)?.recent.count == 3)
        #expect(setup.server.firebaseRequests.isEmpty)
    }

    @Test func pullRefreshesAndASecondPullReusesTheAnswer() async throws {
        let setup = try Self.make()
        let repository = setup.repository
        repository.chooseStandalone()
        let engine = try #require(repository.standalone)
        engine.follow(ChannelInfo(id: Self.channelId, title: "Test", handle: "@TestChannel", avatarURL: "https://a"))
        // The launch check, then the new channel's seed (both read its Live tab).
        #expect(await eventually { setup.youtube.flatURLs.filter { $0 == Self.streamsURL }.count == 2 && !engine.isChecking })
        #expect(engine.state.lastCheck?.trigger == "launch")
        #expect(await repository.pullToRefresh() == .done)
        let requests = setup.server.requests.count
        #expect(await repository.pullToRefresh() == .done)
        #expect(setup.server.requests.count == requests)
        // Automatic checks wait 15 minutes.
        await engine.checkIfDue(.foreground)
        #expect(setup.server.requests.count == requests)
        engine.now = { .now.addingTimeInterval(16 * 60) }
        await engine.checkIfDue(.tick)
        #expect(setup.server.requests.count > requests)
        #expect(setup.server.firebaseRequests.isEmpty)
    }

    @Test func seedingAChannelLeavesTheScheduleAlone() async throws {
        let setup = try Self.make()
        let repository = setup.repository
        repository.chooseStandalone()
        let engine = try #require(repository.standalone)
        #expect(await eventually { engine.state.lastCheck != nil && !engine.isChecking })
        // A full check an hour ago that failed twice in a row and backed off.
        let hourAgo = Date.now.addingTimeInterval(-3600)
        let record = CheckRecord(trigger: "tick", startedAt: hourAgo, finishedAt: hourAgo, channelsChecked: 5, errors: ["X: uploads failed"])
        let backoffUntil = Date.now.addingTimeInterval(20 * 60)
        engine.replaceState {
            $0.lastCheck = record
            $0.failedCheckStreak = 2
            $0.backoffMinutes = 60
            $0.backoffUntil = backoffUntil
        }
        engine.follow(ChannelInfo(id: Self.channelId, title: "Test", handle: "@t", avatarURL: "https://a"))
        #expect(await eventually { repository.channel(Self.channelId)?.recent.count == 3 && !engine.isChecking })
        // Fetched cleanly, but the check schedule, the streak and the backoff are the full check's.
        #expect(engine.state.fetchedAt[Self.channelId]?.uploads != nil)
        #expect(engine.state.lastCheck == record)
        #expect(engine.state.failedCheckStreak == 2)
        #expect(engine.state.backoffMinutes == 60)
        #expect(engine.state.backoffUntil == backoffUntil)
        #expect(engine.checkStatus.lastCheck?.channelsChecked == 5)
        // The footer says when the channels were last read: the seed, not the hour-old check.
        let readAt = try #require(engine.checkStatus.lastReadAt)
        #expect(readAt > hourAgo.addingTimeInterval(30 * 60))
        // The next full check (a pull) is clean: that one resets them.
        #expect(await repository.pullToRefresh() == .done)
        #expect(engine.state.lastCheck?.trigger == "pull")
        #expect(engine.state.failedCheckStreak == 0)
        #expect(engine.state.backoffUntil == nil && engine.state.backoffMinutes == 0)
    }

    @Test func tooManyRequestsBacksOff() async throws {
        let server = try Self.youtubeServer { request in request.path == "/feeds/videos.xml" ? (429, "") : nil }
        let setup = try Self.make(server: server)
        setup.repository.chooseStandalone()
        let engine = try #require(setup.repository.standalone)
        engine.follow(ChannelInfo(id: Self.channelId, title: "Test", handle: "@t", avatarURL: "https://a"))
        #expect(await eventually { engine.state.backoffUntil != nil && !engine.isChecking })
        let before = engine.state.backoffMinutes
        #expect([30, 60].contains(before))
        // Automatic checks wait; pull doesn't, and doubles it.
        let requests = server.requests.count
        await engine.checkIfDue(.foreground)
        #expect(server.requests.count == requests)
        let pull = await setup.repository.pullToRefresh()
        #expect(pull == .slowedDown)
        #expect(engine.state.backoffMinutes == before * 2)
    }

    @Test func aCheckThatCouldntReachYouTubeDoesntCount() async throws {
        let offline = Flag()
        offline.value = true
        let server = try Self.youtubeServer { request in
            offline.value && request.path == "/feeds/videos.xml" ? (StubServer.offline, "") : nil
        }
        let setup = try Self.make(server: server)
        // yt-dlp can't reach YouTube either.
        setup.youtube.flatErrors[Self.streamsURL] = "ERROR: [youtube:tab] Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided, or not known>"
        setup.repository.chooseStandalone()
        let engine = try #require(setup.repository.standalone)
        engine.follow(ChannelInfo(id: Self.channelId, title: "Test", handle: "@t", avatarURL: "https://a"))
        #expect(await engine.refresh() == .youtubeFailed)
        let record = try #require(engine.state.lastCheck)
        #expect(record.offline)
        #expect(record.trigger == "pull")
        #expect(engine.state.backoffUntil == nil)
        #expect(engine.checkStatus.couldntReachYouTube)
        #expect(engine.checkStatus.lastReadAt == nil)
        // Kept in standalone.json.
        #expect(StandaloneStore(directory: setup.directory).load().lastCheck?.offline == true)

        // The next automatic check doesn't wait 15 minutes: it runs, and reaches YouTube this time.
        #expect(await eventually { !engine.isChecking })
        offline.value = false
        setup.youtube.flatErrors = [:]
        await engine.checkIfDue(.tick)
        let online = try #require(engine.state.lastCheck)
        #expect(online.trigger == "tick")
        #expect(!online.offline)
        #expect(!engine.checkStatus.couldntReachYouTube)
        #expect(engine.checkStatus.lastReadAt != nil)
        // Now one does.
        await engine.checkIfDue(.tick)
        #expect(engine.state.lastCheck == online)
        #expect(setup.server.firebaseRequests.isEmpty)
    }

    @Test func aLiveTabWithoutStatesIsNotCountedAsRead() async throws {
        let setup = try Self.make()
        // An older yt-dlp: the Live tab's entries without their live_status.
        setup.youtube.setFlat(Self.streamsURL, #"""
            {"channel":"Test Channel","entries":[{"id":"str00000001","title":"Launch replay"},{"id":"str00000002","title":"Live now"}]}
            """#)
        setup.repository.chooseStandalone()
        let engine = try #require(setup.repository.standalone)
        engine.follow(ChannelInfo(id: Self.channelId, title: "Test", handle: "@t", avatarURL: "https://a"))
        _ = await engine.refresh()
        #expect(engine.state.fetchedAt[Self.channelId]?.uploads != nil)
        #expect(engine.state.fetchedAt[Self.channelId]?.streams == nil)
        #expect(engine.state.lastCheck?.errors.contains { $0.contains("yt-dlp gave no stream states") } == true)
        #expect(engine.state.recentVideos[Self.channelId]?.contains { $0.id.hasPrefix("str") } == false)
        // With the states, the next check reads it.
        setup.youtube.setFlat(Self.streamsURL, Self.streamsJSON)
        engine.now = { .now.addingTimeInterval(16 * 60) }
        await engine.checkIfDue(.tick)
        #expect(engine.state.fetchedAt[Self.channelId]?.streams != nil)
        #expect(engine.state.recentVideos[Self.channelId]?.contains { $0.id == "str00000001" } == true)
    }

    @Test func aBrokenUploadsFeedFallsBackToTheVideosTab() async throws {
        let server = try Self.youtubeServer { request in
            request.query["playlist_id"] == ["UULFtestchannel00000000001"] ? (503, "") : nil
        }
        let setup = try Self.make(server: server)
        setup.youtube.setFlat("https://www.youtube.com/channel/\(Self.channelId)/videos", #"""
            {"channel":"Test","channel_id":"\#(Self.channelId)","entries":[
              {"id":"tab00000001","title":"From the tab","duration":600,"timestamp":1796000000},
              {"id":"tab00000002","url":"https://www.youtube.com/shorts/tab00000002","duration":30}]}
            """#)
        setup.repository.chooseStandalone()
        let engine = try #require(setup.repository.standalone)
        engine.follow(ChannelInfo(id: Self.channelId, title: "Test", handle: "@t", avatarURL: "https://a"))
        #expect(await eventually { setup.repository.item("tab00000001") != nil })
        #expect(setup.repository.item("tab00000002") == nil)
        #expect(await eventually { engine.state.lastCheck != nil && !engine.isChecking })
        #expect(engine.state.backoffUntil == nil)
        // The tab's date is yt-dlp's approximate one: a later check keeps the first one it gave.
        let first = try #require(engine.state.recentVideos[Self.channelId]?.first { $0.id == "tab00000001" }?.publishedAt)
        setup.youtube.setFlat("https://www.youtube.com/channel/\(Self.channelId)/videos", #"""
            {"channel":"Test","channel_id":"\#(Self.channelId)","entries":[
              {"id":"tab00000001","title":"From the tab","duration":600,"timestamp":1796500000}]}
            """#)
        _ = await setup.repository.pullToRefresh()
        #expect(engine.state.recentVideos[Self.channelId]?.first { $0.id == "tab00000001" }?.publishedAt == first)
    }

    @Test func groupsAreLocalAndFollowTheirChannels() async throws {
        let setup = try Self.make()
        let repository = setup.repository
        repository.chooseStandalone()
        let engine = try #require(repository.standalone)
        let group = repository.createGroup("Space")
        let followed = repository.setInGroup(group.id, channel: GroupChannel(id: Self.channelId, title: "Test"), included: true)
        #expect(followed)
        #expect(repository.groups.first?.channels.map(\.id) == [Self.channelId])
        #expect(repository.followedIds == [Self.channelId])
        // Its picture and handle come from its page.
        #expect(await eventually { engine.channels.first?.avatarURL == "https://yt3.googleusercontent.com/fake-avatar=s900" })
        // Already followed: no "following too".
        let second = repository.createGroup("Again")
        #expect(!repository.setInGroup(second.id, channel: GroupChannel(id: Self.channelId, title: "Test"), included: true))
        repository.moveGroup(second.id, by: -1)
        #expect(repository.groups.map(\.name) == ["Again", "Space"])
        // Unfollowing takes it out of every group.
        engine.unfollow(Self.channelId)
        #expect(repository.groups.allSatisfy { $0.channels.isEmpty })
        #expect(repository.channels.isEmpty)
        #expect(engine.state.recentVideos[Self.channelId] == nil)
        // Kept in standalone.json.
        let again = try Self.make(server: setup.server, defaults: setup.defaults, directory: setup.directory)
        #expect(again.repository.groups.map(\.name) == ["Again", "Space"])
        #expect(setup.server.firebaseRequests.isEmpty)
    }

    @Test func downloadsNeverAskTheMac() async throws {
        let setup = try Self.make()
        let repository = setup.repository
        repository.chooseStandalone()
        let engine = try #require(repository.standalone)
        engine.follow(ChannelInfo(id: Self.channelId, title: "Test", handle: "@t", avatarURL: "https://a"))
        #expect(await eventually { repository.item("vid00000001") != nil })
        let item = try #require(repository.item("vid00000001"))
        repository.download(item)
        #expect(repository.local["vid00000001"]?.requestedAt == nil)
        #expect(repository.local["vid00000001"]?.video?.id == "vid00000001")
        // Unfollowed: the download stays listed.
        engine.unfollow(Self.channelId)
        #expect(repository.item("vid00000001")?.state == .queued)
        #expect(repository.downloadItems.map(\.id) == ["vid00000001"])
        // Watched lives on the phone.
        repository.setWatched("vid00000001", true)
        #expect(repository.prefs.watchedHere.contains("vid00000001"))
        #expect(repository.item("vid00000001")?.watched == true)
        #expect(setup.server.firebaseRequests.isEmpty)
    }

    @Test func expiredCookiesShowTheBannerOnceAndSignOutClears() async throws {
        let setup = try Self.make()
        let repository = setup.repository
        var notifications = 0
        repository.onYouTubeSignedOut = { notifications += 1 }
        repository.chooseStandalone()
        let engine = try #require(repository.standalone)
        try await engine.signIn(cookies: try fixture("fake-cookies.txt"), source: .file, verify: false)
        #expect(engine.accountInfo.state == .signedIn)
        #expect(engine.accountInfo.source == .file)
        #expect(setup.vault.load() != nil)
        #expect(!(try String(contentsOf: engine.store.file, encoding: .utf8)).contains("FAKE"))
        setup.youtube.setRejectCookies(true)
        _ = await repository.pullToRefresh()
        #expect(engine.accountInfo.state == .expired)
        #expect(engine.showsExpiredBanner)
        #expect(notifications == 1)
        #expect(engine.cookiesFile() == nil)
        // While expired, no members, feeds or history reads; and it stays expired (one notification).
        let calls = setup.youtube.flatURLs.count
        engine.now = { .now.addingTimeInterval(2 * 60) }
        _ = await repository.pullToRefresh()
        #expect(!setup.youtube.flatURLs.dropFirst(calls).contains { $0.hasPrefix(":") || $0.contains("list=UUM") })
        #expect(notifications == 1)
        engine.closeExpiredBanner()
        #expect(!engine.showsExpiredBanner)
        // A members-only download says why.
        let members = Video(id: "mem00000001", channelId: Self.channelId, channelTitle: "T", title: "M", publishedAt: nil,
                            thumbnailURL: nil, isMembersOnly: true)
        #expect(repository.downloadFailure(members, error: nil) == "YouTube signed you out. Sign in again in Settings.")

        engine.signOut()
        #expect(engine.accountInfo.state == .signedOut)
        #expect(setup.vault.load() == nil)
        #expect(engine.state.accountFeeds == nil && engine.state.youTubeHistory.isEmpty && engine.state.pendingYouTubeWatched.isEmpty)
        #expect(repository.downloadFailure(members, error: nil) == "Members-only. Sign in to YouTube in Settings.")
        #expect(setup.server.firebaseRequests.isEmpty)
    }

    @Test func signedInReadsFeedsAndSyncsWatched() async throws {
        let setup = try Self.make()
        let repository = setup.repository
        repository.chooseStandalone()
        let engine = try #require(repository.standalone)
        engine.follow(ChannelInfo(id: Self.channelId, title: "Test", handle: "@t", avatarURL: "https://a"))
        #expect(await eventually { repository.item("vid00000002") != nil })
        let youtube = setup.youtube
        youtube.setFlat(":ytrec", #"{"entries":[{"id":"rec00000001","title":"Rec","channel":"Other","channel_id":"UCother0000000000000000a","duration":300},{"id":"mem00000009","title":"M","channel":"Other","channel_id":"UCother0000000000000000a","duration":300,"availability":"subscriber_only"}]}"#)
        youtube.setFlat(":ytsubs", #"{"entries":[{"id":"vid00000001","title":"From feed","channel":"Test","channel_id":"\#(Self.channelId)","duration":620}]}"#)
        youtube.setFlat(":ythistory", #"{"entries":[{"id":"vid00000002"},{"id":"unknown0001"}]}"#)
        // A rejected verification isn't stored.
        youtube.setRejectCookies(true)
        await #expect(throws: StandaloneError.rejected) {
            try await engine.signIn(cookies: try fixture("fake-cookies.txt"), source: .web)
        }
        #expect(setup.vault.load() == nil)
        youtube.setRejectCookies(false)
        try await engine.signIn(cookies: try fixture("fake-cookies.txt"), source: .web)
        #expect(await eventually { engine.state.lastWatchSync != nil && engine.state.accountFeeds != nil })
        // The members-only one shows once its access is known (the fake's lookup says watchable).
        #expect(engine.state.access("mem00000009") == .watchable)
        #expect(repository.recommended.map(\.id) == ["rec00000001", "mem00000009"])
        // A feed video without a date takes the channel's known date.
        #expect(repository.youtubeFeeds.subscriptions.first?.publishedAt != nil)
        // Watched on YouTube: watched here, for videos the phone knows.
        #expect(repository.item("vid00000002")?.watched == true)
        #expect(!repository.prefs.watchedHere.contains("unknown0001"))
        // Marked here: sent to YouTube.
        repository.setWatched("vid00000001", true)
        #expect(await eventually { youtube.marked == ["vid00000001"] })
        #expect(await eventually { engine.state.pendingYouTubeWatched.isEmpty })
        #expect(youtube.flatCalls.contains { $0.url.contains("list=UUMF") && $0.cookies })
        #expect(setup.server.firebaseRequests.isEmpty)
    }

    @Test func aSignInLeftByAnEarlierInstallIsDeleted() throws {
        // The Keychain outlives a deleted app; standalone.json doesn't.
        let vault = InMemoryCookieVault(Data(try fixture("fake-cookies.txt").utf8))
        let setup = try Self.make(vault: vault)
        setup.repository.chooseStandalone()
        #expect(setup.repository.standalone?.accountInfo.state == .signedOut)
        #expect(vault.load() == nil)
        // Choosing the Mac deletes it too.
        let other = InMemoryCookieVault(Data(try fixture("fake-cookies.txt").utf8))
        let mac = try Self.make(vault: other)
        mac.repository.chooseMac()
        #expect(other.load() == nil)
        #expect(mac.server.firebaseRequests.isEmpty)
    }

    @Test func aSignInTheKeychainRefusesIsNotReportedAsOne() async throws {
        let vault = InMemoryCookieVault()
        let setup = try Self.make(vault: vault)
        setup.repository.chooseStandalone()
        let engine = try #require(setup.repository.standalone)
        vault.failSaves = true
        await #expect(throws: StandaloneError.self) {
            try await engine.signIn(cookies: try fixture("fake-cookies.txt"), source: .file, verify: false)
        }
        #expect(engine.accountInfo.state == .signedOut)
        // A later launch doesn't find a sign-in without cookies.
        vault.failSaves = false
        let again = try Self.make(server: setup.server, defaults: setup.defaults, directory: setup.directory, vault: vault)
        #expect(again.repository.standalone?.accountInfo.state == .signedOut)
    }

    @Test func switchingToStandaloneEndsAPullThatWaitsForTheMac() async throws {
        let defaults = freshDefaults()
        defaults.set("stow-test", forKey: "pairedProject")
        defaults.set(Data((0..<32).map { UInt8($0) }).base64URLEncodedString, forKey: "pairingKey")
        let server = try Self.youtubeServer { request in
            guard firebaseHosts.contains(request.url.host() ?? "") else { return nil }
            switch request.path {
            case "\(documentsPrefix):commit":
                return (200, #"{"writeResults":[{"updateTime":"2026-11-27T09:00:00.1Z","transformResults":[{"timestampValue":"2026-11-27T09:00:00.1Z"}]}],"commitTime":"2026-11-27T09:00:00.1Z"}"#)
            // The Mac never answers the refresh request.
            case "\(documentsPrefix)/shared/phone": return (200, #"{"name":"x/shared/phone","fields":{}}"#)
            case "\(documentsPrefix)/videos", "\(documentsPrefix)/channels": return (200, "{}")
            default: return (404, #"{"error":{"code":404,"status":"NOT_FOUND"}}"#)
            }
        }
        let setup = try Self.make(server: server, defaults: defaults, tokens: InMemoryTokenStore(validTokens()))
        let repository = setup.repository
        #expect(repository.isPaired)
        let pull = Task { await repository.pullToRefresh() }
        #expect(await eventually { server.firebaseRequests.contains { $0.path == "\(documentsPrefix):commit" } })
        let started = ContinuousClock.now
        repository.switchToStandalone(keepChannels: false)
        let firebaseBefore = server.firebaseRequests.count
        // It stops at its next look (every 3 s), not after the 2-minute wait, and asks Firebase nothing more.
        #expect(await pull.value == .failed)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(server.firebaseRequests.count == firebaseBefore)
        #expect(repository.mode == .standalone)
    }

    @Test func aRetiredRemoteIsRefusedQuietly() async throws {
        let guardian = FirebaseGuard(mode: .mac)
        let era = try #require(guardian.openEra)
        try guardian.check(era: era)
        guardian.set(.standalone)
        // Work a Mac-mode Remote started: refused, without the debug assertion.
        #expect(throws: CancellationError.self) { try guardian.check(era: era) }
        guardian.set(.mac)
        #expect(throws: CancellationError.self) { try guardian.check(era: era) }
        let now = try #require(guardian.openEra)
        try guardian.check(era: now)
        try guardian.check()
    }

    @Test func aPairedInstallStaysPaired() throws {
        let defaults = freshDefaults()
        defaults.set("stow-test", forKey: "pairedProject")
        defaults.set("a2V5", forKey: "pairingKey")
        let setup = try Self.make(defaults: defaults, tokens: InMemoryTokenStore(validTokens()))
        #expect(setup.repository.mode == .mac)
        #expect(setup.repository.isPaired)
        #expect(setup.repository.remote != nil)
        #expect(defaults.string(forKey: "appMode") == "mac")
        #expect(setup.repository.standalone == nil)
        // -standalone is ignored when paired (the app checks before building the repository).
        #expect(setup.repository.followedIds.isEmpty)
    }

    @Test func standaloneToMacAndBack() async throws {
        let setup = try Self.make()
        let repository = setup.repository
        repository.chooseStandalone()
        let engine = try #require(repository.standalone)
        engine.follow(ChannelInfo(id: Self.channelId, title: "Test", handle: "@t", avatarURL: "https://a"))
        _ = repository.createGroup("Space", with: GroupChannel(id: Self.channelId, title: "Test"))
        try await engine.signIn(cookies: try fixture("fake-cookies.txt"), source: .file, verify: false)
        #expect(await eventually { engine.state.lastCheck != nil })

        repository.switchToMac()
        #expect(repository.mode == .mac)
        #expect(repository.prefs.appMode == "mac")
        #expect(repository.remote != nil)
        #expect(repository.pairState == .unpaired(message: nil))
        #expect(repository.standalone == nil)
        #expect(repository.channels.isEmpty && repository.groups.isEmpty)
        // The sign-in is gone; standalone.json stays.
        #expect(setup.vault.load() == nil)
        #expect(FileManager.default.fileExists(atPath: setup.directory.appending(path: "standalone.json").path))

        // "Use on its own instead": all back, nothing copied, still signed out.
        repository.switchToStandalone(keepChannels: false)
        #expect(repository.mode == .standalone)
        #expect(repository.remote == nil)
        #expect(repository.followedIds == [Self.channelId])
        #expect(repository.groups.map(\.name) == ["Space"])
        #expect(repository.standalone?.accountInfo.state == .signedOut)
        #expect(repository.standalone?.showsSignInPrompt == false)
        #expect(setup.server.firebaseRequests.isEmpty)
    }

    /// A phone paired with a (stubbed) Mac; `switched` makes Firebase answer 500 from then on.
    static func pairedWithTheMac(directory: URL = temporaryDirectory()) throws -> (Setup, Flag) {
        let key = Data((0..<32).map { UInt8($0 * 3) })
        let defaults = freshDefaults()
        defaults.set("stow-test", forKey: "pairedProject")
        defaults.set(key.base64URLEncodedString, forKey: "pairingKey")
        let switched = Flag()
        let server = try Self.youtubeServer { request in
            guard firebaseHosts.contains(request.url.host() ?? "") else { return nil }
            if switched.value { return (500, "{}") }
            switch request.path {
            case "\(documentsPrefix)/videos": return (200, try! fixture("videos-list.json"))
            case "\(documentsPrefix)/channels": return (200, try! fixture("channels-list.json"))
            case "\(documentsPrefix)/shared/phone": return (200, try! fixture("shared-phone.json"))
            default: return (404, #"{"error":{"code":404,"status":"NOT_FOUND"}}"#)
            }
        }
        let setup = try Self.make(server: server, defaults: defaults, directory: directory, tokens: InMemoryTokenStore(validTokens()))
        return (setup, switched)
    }

    @Test func macToStandaloneKeepsTheMacsChannels() async throws {
        let (setup, switched) = try Self.pairedWithTheMac()
        let server = setup.server
        let repository = setup.repository
        #expect(repository.mode == .mac)
        #expect(await repository.refresh())
        let macChannels = repository.channels.map(\.id)
        let macGroups = repository.groups.map(\.name)
        try #require(!macChannels.isEmpty)
        let watchedOnMac = repository.items.values.filter(\.watched).map(\.id)
        #expect(!watchedOnMac.isEmpty)

        switched.value = true
        let firebaseBefore = server.firebaseRequests.count
        repository.switchToStandalone(keepChannels: true)
        #expect(repository.mode == .standalone)
        #expect(repository.prefs.pairedProject == nil)
        #expect(repository.remote == nil)
        #expect(!repository.isPaired)
        let engine = try #require(repository.standalone)
        #expect(Array(engine.channels.map(\.id).prefix(macChannels.count)) == macChannels)
        #expect(repository.groups.map(\.name) == macGroups)
        // The Mac's recent videos count as read just now, past streams included.
        for id in macChannels {
            #expect(engine.state.fetchedAt[id]?.uploads != nil)
            #expect(engine.state.fetchedAt[id]?.streams != nil)
        }
        #expect(engine.checkStatus.lastReadAt != nil)
        for id in watchedOnMac { #expect(repository.prefs.watchedHere.contains(id)) }
        #expect(engine.showsSignInPrompt)
        // Never checked here: the launch check is due. It reads the uploads, not every Live tab.
        #expect(await eventually { engine.state.lastCheck?.trigger == "launch" && !engine.isChecking })
        #expect(!setup.youtube.flatURLs.contains { url in macChannels.contains { url.contains($0) } })
        #expect(server.firebaseRequests.count == firebaseBefore)
    }

    @Test func macToStandaloneChecksOnlyWhenDue() async throws {
        // An earlier standalone stay checked five minutes ago.
        let directory = temporaryDirectory()
        var earlier = StandaloneState()
        earlier.channels = [FollowedChannel(id: Self.channelId, title: "Test")]
        // Whole milliseconds, as standalone.json keeps them.
        let fiveMinutesAgo = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 - 5 * 60).rounded())
        let record = CheckRecord(trigger: "tick", startedAt: fiveMinutesAgo, finishedAt: fiveMinutesAgo, channelsChecked: 1, errors: [])
        earlier.lastCheck = record
        earlier.fetchedAt[Self.channelId] = FeedTimes(uploads: fiveMinutesAgo, streams: fiveMinutesAgo)
        StandaloneStore(directory: directory).save(earlier)

        let (setup, switched) = try Self.pairedWithTheMac(directory: directory)
        let repository = setup.repository
        #expect(await repository.refresh())
        let macChannels = repository.channels.map(\.id)
        try #require(!macChannels.isEmpty)
        switched.value = true
        let requests = setup.server.requests.count
        repository.switchToStandalone(keepChannels: true)
        let engine = try #require(repository.standalone)
        #expect(engine.channels.first?.id == Self.channelId)
        #expect(macChannels.allSatisfy(engine.isFollowing))
        for _ in 0..<20 { await Task.yield() }
        await engine.checkIfDue(.launch)
        // Not due: no check ran, nothing was fetched.
        #expect(engine.state.lastCheck == record)
        #expect(setup.server.requests.count == requests)
        #expect(setup.youtube.flatURLs.isEmpty)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
