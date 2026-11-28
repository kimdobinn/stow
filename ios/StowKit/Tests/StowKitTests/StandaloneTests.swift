import Foundation
import Testing
@testable import StowKit

/// Standalone mode's pure parts: the same cases as the Android app's JVM tests.
@Suite struct AppModeTests {
    @Test func storedValuesWin() {
        #expect(AppMode.resolve(stored: "mac", hasPairing: false) == (.mac, nil))
        #expect(AppMode.resolve(stored: "standalone", hasPairing: true) == (.standalone, nil))
    }

    @Test func aPairedInstallBecomesMacMode() {
        #expect(AppMode.resolve(stored: nil, hasPairing: true) == (.mac, "mac"))
        #expect(AppMode.resolve(stored: "nonsense", hasPairing: true) == (.mac, "mac"))
    }

    @Test func aFreshInstallChooses() {
        #expect(AppMode.resolve(stored: nil, hasPairing: false) == (.choosing, nil))
    }

    @MainActor @Test func prefsWriteTheMigration() {
        let defaults = freshDefaults()
        let prefs = Prefs(defaults: defaults)
        #expect(prefs.resolveMode() == .choosing)
        #expect(prefs.appMode == nil)
        prefs.savePairing(projectId: "stow-test", keyBase64URL: "a2V5")
        #expect(prefs.resolveMode() == .mac)
        #expect(defaults.string(forKey: "appMode") == "mac")
        // Unpaired later: still Mac mode (the pair screen), as today.
        prefs.clearPairing()
        #expect(prefs.resolveMode() == .mac)
    }
}

@Suite struct NetscapeCookiesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func formatsLikeTheMac() {
        let cookies = [
            NetscapeCookie(domain: ".youtube.com", path: "/", secure: true, expires: Date(timeIntervalSince1970: 1_900_000_000), name: "SAPISID", value: "abc/def"),
            NetscapeCookie(domain: "www.youtube.com", path: "/", secure: false, expires: nil, name: "VISITOR", value: "v"),
            NetscapeCookie(domain: ".google.com", path: "/", secure: true, expires: Date(timeIntervalSince1970: 1_900_000_000), name: "SID", value: "s"),
            NetscapeCookie(domain: ".example.com", expires: nil, name: "OTHER", value: "x"),
            NetscapeCookie(domain: ".youtube.com", expires: nil, name: "BAD", value: "has\ttab"),
            NetscapeCookie(domain: ".youtube.com", expires: nil, name: "BAD2", value: "line\nbreak"),
        ]
        let text = NetscapeCookies.format(cookies, now: now)
        let sessionExpiry = String(Int(now.timeIntervalSince1970 + 365 * 86_400))
        #expect(text == """
        # Netscape HTTP Cookie File

        .google.com\tTRUE\t/\tTRUE\t1900000000\tSID\ts
        .youtube.com\tTRUE\t/\tTRUE\t1900000000\tSAPISID\tabc/def
        www.youtube.com\tFALSE\t/\tFALSE\t\(sessionExpiry)\tVISITOR\tv

        """)
    }

    @Test func parsesHttpOnlyAndSkipsTheRest() throws {
        let text = """
        # Netscape HTTP Cookie File
        # a comment

        #HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t4102444800\tLOGIN_INFO\tL
        .youtube.com\tTRUE\t/\tTRUE\t4102444800\tSAPISID\ts\r
        .example.com\tTRUE\t/\tTRUE\t4102444800\tTRACK\tt
        accounts.google.com\tFALSE\t/\tTRUE\t0\tLSID\tx
        too\tfew\tfields
        """
        let cookies = NetscapeCookies.parse(text)
        #expect(cookies.map(\.name) == ["LOGIN_INFO", "SAPISID", "LSID"])
        #expect(cookies[1].value == "s")
        #expect(cookies[2].expires == nil)
        #expect(cookies[2].includeSubdomains == false)
        #expect(NetscapeCookies.isSignedIn(cookies, now: now))
    }

    @Test func fingerprintNeedsLoginInfoAndASapisid() throws {
        let fake = NetscapeCookies.parse(try fixture("fake-cookies.txt"))
        #expect(NetscapeCookies.sessionFingerprint(fake, now: now) == "LOGIN_INFO=FAKE;SAPISID=fake/fake;__Secure-3PAPISID=fake/fake")
        let onlyGoogle = [NetscapeCookie(domain: ".google.com", expires: nil, name: "SAPISID", value: "x"),
                          NetscapeCookie(domain: ".google.com", expires: nil, name: "LOGIN_INFO", value: "x")]
        #expect(NetscapeCookies.sessionFingerprint(onlyGoogle, now: now) == nil)
        let expired = [NetscapeCookie(domain: ".youtube.com", expires: now.addingTimeInterval(-1), name: "LOGIN_INFO", value: "x"),
                       NetscapeCookie(domain: ".youtube.com", expires: nil, name: "__Secure-1PAPISID", value: "y")]
        #expect(NetscapeCookies.sessionFingerprint(expired, now: now) == nil)
        #expect(NetscapeCookies.loginInfoExpiry(expired) == now.addingTimeInterval(-1))
    }

    @Test func exportsHTTPCookies() throws {
        // Foundation caps a cookie's life at 400 days: an expiry inside that stays as it is.
        let expiry = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 30 * 86_400).rounded())
        let cookie = try #require(HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "LOGIN_INFO", .value: "v",
                                                         .secure: "TRUE", .expires: expiry]))
        let hostOnly = try #require(HTTPCookie(properties: [.domain: "accounts.google.com", .path: "/", .name: "__Host-GAPS", .value: "g"]))
        let text = NetscapeCookies.format(httpCookies: [cookie, hostOnly], now: now)
        #expect(text.contains(".youtube.com\tTRUE\t/\tTRUE\t\(Int(expiry.timeIntervalSince1970))\tLOGIN_INFO\tv"))
        #expect(text.contains("accounts.google.com\tFALSE\t/\tFALSE\t\(Int(now.timeIntervalSince1970 + 365 * 86_400))\t__Host-GAPS\tg"))
    }

    @Test func validatesAFile() throws {
        #expect(throws: StandaloneError.noSignIn) { try YouTubeAccount.validated("# Netscape HTTP Cookie File\n", now: now) }
        let text = try YouTubeAccount.validated(try fixture("fake-cookies.txt") + ".other.com\tTRUE\t/\tTRUE\t0\tX\ty\n", now: now)
        #expect(!text.contains("other.com"))
        #expect(text.contains("LOGIN_INFO\tFAKE"))
    }

    @Test func cookieHeaderAddsConsent() throws {
        let cookies = NetscapeCookies.parse(try fixture("fake-cookies.txt"))
        #expect(NetscapeCookies.cookieHeader(cookies, now: now) == "LOGIN_INFO=FAKE; SAPISID=fake/fake; __Secure-3PAPISID=fake/fake; SOCS=CAI")
    }

    @Test func temporaryFilesArePrivate() throws {
        let account = YouTubeAccount(vault: InMemoryCookieVault(Data("x".utf8)))
        let file = try #require(account.temporaryFile())
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.lastPathComponent.hasPrefix("cookies-"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(YouTubeAccount(vault: InMemoryCookieVault()).temporaryFile() == nil)
    }
}

@Suite struct ChannelResolverTests {
    @Test func parsesEveryForm() {
        let id = "UCLA_DiR1FfKNvjuUpBHmylQ"
        #expect(ChannelResolver.parse(input: id) == .id(id))
        #expect(ChannelResolver.parse(input: "  \(id)\n") == .id(id))
        #expect(ChannelResolver.parse(input: "@NASA") == .handle("NASA"))
        #expect(ChannelResolver.parse(input: "NASA") == .handle("NASA"))
        #expect(ChannelResolver.parse(input: "https://www.youtube.com/@NASA") == .handle("NASA"))
        #expect(ChannelResolver.parse(input: "youtube.com/@NASA/videos") == .handle("NASA"))
        #expect(ChannelResolver.parse(input: "https://m.youtube.com/channel/\(id)") == .id(id))
        #expect(ChannelResolver.parse(input: "https://www.youtube.com/c/NASA") == .url(URL(string: "https://www.youtube.com/c/NASA")!))
        #expect(ChannelResolver.parse(input: "https://www.youtube.com/user/NASAtelevision") == .url(URL(string: "https://www.youtube.com/user/NASAtelevision")!))
        #expect(ChannelResolver.parse(input: "https://www.youtube.com/watch?v=abcdefghijk&t=3") == .video("abcdefghijk"))
        #expect(ChannelResolver.parse(input: "https://youtu.be/abcdefghijk") == .video("abcdefghijk"))
        for path in ["shorts", "live", "embed", "v"] {
            #expect(ChannelResolver.parse(input: "https://www.youtube.com/\(path)/abcdefghijk") == .video("abcdefghijk"))
        }
        #expect(ChannelResolver.parse(input: "@テスト") == .handle("テスト"))
    }

    @Test func refusesWhatIsntAChannel() {
        #expect(ChannelResolver.parse(input: "not a channel!!") == nil)
        #expect(ChannelResolver.parse(input: "https://www.youtube.com/channel/notanid") == nil)
        #expect(ChannelResolver.parse(input: "https://www.youtube.com/feed/trending") == nil)
        #expect(ChannelResolver.parse(input: "https://youtu.be/short") == nil)
        #expect(StandaloneError.invalidInput("not a channel!!").message == "Not a channel URL, @handle or channel ID: not a channel!!")
        #expect(StandaloneError.alreadyAdded("NASA").message == "NASA is already added.")
        #expect(StandaloneError.notFound("@x").message == "Channel not found: @x")
    }

    @Test func readsAChannelPage() throws {
        let info = try #require(ChannelPageParser.parse(html: try fixture("channel-page.html")))
        #expect(info == ChannelInfo(id: "UCtestchannel00000000001", title: "Test & Channel", handle: "@TestChannel",
                                    avatarURL: "https://yt3.googleusercontent.com/fake-avatar=s900"))
        #expect(ChannelPageParser.parse(html: "<html>consent</html>") == nil)
        let externalOnly = #"<meta property="og:title" content="X">"externalId":"UCsecondchannel000000002""#
        #expect(ChannelPageParser.parse(html: externalOnly)?.id == "UCsecondchannel000000002")
        #expect(ChannelPageParser.ownerChannelId(watchPage: #"{"videoDetails":{"channelId":"UCsecondchannel000000002"},"x":{"channelId":"UCthirdchannel0000000003"}}"#)
                == "UCsecondchannel000000002")
    }
}

@Suite struct RSSFeedTests {
    @Test func parsesAnAtomFeed() throws {
        let videos = try RSSFeed.parse(Data(try fixture("rss-uploads.xml").utf8))
        #expect(videos.map(\.id) == ["vid00000001", "vid00000002"])
        let first = try #require(videos.first)
        #expect(first.title == "Rockets & Moons")
        #expect(first.channelId == "UCtestchannel00000000001")
        #expect(first.channelTitle == "Test Channel")
        #expect(first.publishedAt == ISO8601DateFormatter().date(from: "2026-11-20T15:00:00Z"))
        #expect(first.thumbnailURL == "https://i1.ytimg.com/vi/vid00000001/hqdefault.jpg")
        #expect(first.liveStatus == "unknown")
        #expect(!first.isMembersOnly)
        #expect(throws: (any Error).self) { try RSSFeed.parse(Data("<html/>".utf8)) }
    }

    @Test func playlistIds() {
        let id = "UCLA_DiR1FfKNvjuUpBHmylQ"
        #expect(PlaylistID.longForm(channelId: id) == "UULFLA_DiR1FfKNvjuUpBHmylQ")
        #expect(PlaylistID.liveStreams(channelId: id) == "UULVLA_DiR1FfKNvjuUpBHmylQ")
        #expect(PlaylistID.membersOnly(channelId: id) == "UUMFLA_DiR1FfKNvjuUpBHmylQ")
        #expect(PlaylistID.membersStreams(channelId: id) == "UUMVLA_DiR1FfKNvjuUpBHmylQ")
    }

    @Test func aMissingUploadsFeedProbesTheChannel() throws {
        #expect(try RSSFeed.probeAnswer(status: 200, channelId: "UCx").isEmpty)
        #expect(throws: StandaloneError.notFound("UCx")) { try RSSFeed.probeAnswer(status: 404, channelId: "UCx") }
        #expect(throws: StandaloneError.rateLimited) { try RSSFeed.probeAnswer(status: 429, channelId: "UCx") }
    }

    @Test func uploadsOverHTTP() async throws {
        let rss = try fixture("rss-uploads.xml")
        let flaky = Flag()
        let server = StubServer { request in
            if request.query["playlist_id"] == ["UULFtestchannel00000000001"] { return (200, rss) }
            if request.query["playlist_id"] == ["UULFnolongform0000000000"] { return (404, "") }
            if request.query["channel_id"] == ["UCnolongform0000000000"] { return (200, "<feed/>") }
            if request.query["playlist_id"] == ["UULFflaky00000000000000"] {
                flaky.value.toggle()
                return flaky.value ? (503, "") : (200, rss)
            }
            return (404, "")
        }
        let web = YouTubeWeb(session: server.session)
        #expect(try await RSSFeed.uploads(channelId: "UCtestchannel00000000001", web: web).count == 2)
        #expect(try await RSSFeed.uploads(channelId: "UCnolongform0000000000", web: web).isEmpty)
        // A 503 now and then is tried again.
        #expect(try await RSSFeed.uploads(channelId: "UCflaky00000000000000", web: web).count == 2)
        await #expect(throws: StandaloneError.notFound("UCgonechannel00000000000")) {
            _ = try await RSSFeed.uploads(channelId: "UCgonechannel00000000000", web: web)
        }
        let first = try #require(server.requests.first)
        #expect(first.headers["User-Agent"] == YouTubeWeb.userAgent)
        #expect(first.headers["Cookie"] == "SOCS=CAI")
        #expect(first.headers["Accept-Language"] == "en-US,en;q=0.9")
    }
}

@Suite struct FeedParsingTests {
    let channel = "UCtestchannel00000000001"

    @Test func pastStreamsKeepOnlyFinishedOnesTheFeedLists() {
        let tab = #"""
        {"channel":"Test Channel","entries":[
          {"id":"str00000001","title":"Translated","live_status":"was_live","duration":3600,"timestamp":1790000000},
          {"id":"str00000002","title":"Live now","live_status":"is_live"},
          {"id":"str00000003","title":"Soon","live_status":"is_upcoming"},
          {"id":"str00000004","title":"Old","live_status":"was_live"},
          {"id":"str00000001","title":"Again","live_status":"was_live"},
          null
        ]}
        """#
        let all = ChannelChecker.streams(fromTabJSON: tab, channelId: channel, feed: nil)
        #expect(all.map(\.id) == ["str00000001", "str00000004"])
        #expect(all.first?.isPastStream == true)
        #expect(all.first?.durationSeconds == 3600)
        #expect(all.first?.publishedAt == Date(timeIntervalSince1970: 1_790_000_000))
        let original = Video(id: "str00000001", channelId: channel, channelTitle: "Test Channel", title: "Original title",
                             publishedAt: Date(timeIntervalSince1970: 1_780_000_000), thumbnailURL: "https://t/1.jpg", isMembersOnly: false)
        let listed = ChannelChecker.streams(fromTabJSON: tab, channelId: channel, feed: [original])
        #expect(listed.map(\.id) == ["str00000001"])
        #expect(listed.first?.title == "Original title")
        #expect(listed.first?.publishedAt == original.publishedAt)
    }

    @Test func aLiveTabWithoutStatesIsntRead() {
        #expect(ChannelChecker.hasStates(tabJSON: #"{"entries":[{"id":"str00000001","live_status":"was_live"},{"id":"str00000002"}]}"#))
        #expect(ChannelChecker.hasStates(tabJSON: #"{"entries":[]}"#))
        #expect(ChannelChecker.hasStates(tabJSON: #"{"channel":"No tab"}"#))
        #expect(ChannelChecker.hasStates(tabJSON: "not json"))
        #expect(!ChannelChecker.hasStates(tabJSON: #"{"entries":[{"id":"str00000001","title":"A"},{"id":"str00000002","live_status":null}]}"#))
        #expect(!ChannelChecker.hasStates(tabJSON: #"{"entries":[{"id":"str00000001","live_status":""}]}"#))
    }

    @Test func membersPlaylistAndOriginalMetadata() throws {
        let json = #"""
        {"channel":"Test Channel","channel_id":"UCtestchannel00000000001","entries":[
          {"id":"mem00000001","title":"Übersetzt","live_status":"not_live","duration":900},
          {"id":"mem00000002","title":"[Private video]"},
          {"id":"mem00000003","title":"Streaming","live_status":"post_live"},
          {"id":"mem00000004","title":"Old stream","live_status":"was_live","release_timestamp":1780000000}
        ]}
        """#
        let videos = try ChannelChecker.parseMembers(json, channelId: channel)
        #expect(videos.map(\.id) == ["mem00000001", "mem00000003", "mem00000004"])
        #expect(videos.allSatisfy { $0.isMembersOnly })
        #expect(videos[1].liveStatus == "is_live")
        #expect(videos[2].isPastStream)
        #expect(videos[0].publishedAt == nil)
        let feed = [Video(id: "mem00000001", channelId: channel, channelTitle: "Test Channel", title: "Original",
                          publishedAt: Date(timeIntervalSince1970: 1_790_000_000), thumbnailURL: nil, isMembersOnly: false)]
        let corrected = ChannelChecker.applyOriginalMetadata(videos, from: feed)
        #expect(corrected[0].title == "Original")
        #expect(corrected[0].publishedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(corrected[0].isMembersOnly)
    }

    @Test func memberAccessFromLookupAndError() {
        #expect(MemberAccess.fromLookup(#"{"availability":"subscriber_only"}"#) == .watchable)
        #expect(MemberAccess.fromLookup(#"{"availability":"public"}"#) == .nowPublic)
        #expect(MemberAccess.fromLookup(#"{"availability":"unlisted"}"#) == .nowPublic)
        #expect(MemberAccess.fromError("ERROR: This video is available to this channel's members on level: Gold (or any higher level).") == .locked(level: "Gold"))
        #expect(MemberAccess.fromError("Join this channel to get access to members-only content like this video") == .locked(level: nil))
        #expect(MemberAccess.fromError("Requested format is not available") == .watchable)
        #expect(MemberAccess.fromError("Something else") == nil)
        for access in [MemberAccess.watchable, .nowPublic, .locked(level: nil), .locked(level: "Gold")] {
            #expect(MemberAccess(stored: access.stored) == access)
        }
        #expect(MemberAccess.locked(level: "Gold").stored == "locked:Gold")
    }

    @Test func homeAndSubscriptionsLeaveOutShortsAndLive() throws {
        let json = #"""
        {"entries":[
          {"id":"feed0000001","title":"Long","channel":"A","channel_id":"UCa","duration":600,"thumbnails":[{"url":"s","width":10},{"url":"w","width":100}]},
          {"id":"feed0000002","title":"Short","channel":"A","channel_id":"UCa","duration":45},
          {"id":"feed0000003","url":"https://www.youtube.com/shorts/feed0000003","channel_id":"UCa"},
          {"id":"feed0000004","live_status":"is_live","channel_id":"UCa"},
          {"id":"feed0000005","live_status":"is_upcoming","channel_id":"UCa"},
          {"id":"feed0000006","live_status":"post_live","channel_id":"UCa"},
          {"id":"feed0000007","live_status":"was_live","channel_id":"UCa","duration":7200,"availability":"subscriber_only"},
          {"id":"playlist","title":"A mix"}
        ]}
        """#
        let videos = try YouTubeListing.parse(json)
        #expect(videos.map(\.id) == ["feed0000001", "feed0000007"])
        #expect(videos[0].thumbnailURL == "w")
        #expect(videos[1].isMembersOnly)
        #expect(StoredVideo(videos[1]).liveStatus == "wasLive")
    }

    @Test func classifiesFailures() {
        #expect(YouTubeFailure.classify("ERROR: The provided YouTube account cookies are no longer valid") == .auth)
        #expect(YouTubeFailure.classify("Sign in to confirm. Use --cookies-from-browser or --cookies for the authentication.") == .auth)
        #expect(YouTubeFailure.classify("ERROR: Unable to download webpage: HTTP Error 404: Not Found") == .unavailable)
        #expect(YouTubeFailure.classify("This channel does not have a streams tab") == .unavailable)
        #expect(YouTubeFailure.classify("ERROR: Unable to download webpage: <urlopen error timed out>") == .network)
        #expect(YouTubeFailure.classify("HTTP Error 429: Too Many Requests") == .network)
        #expect(YouTubeFailure.classify("HTTP Error 503: Service Unavailable") == .network)
        #expect(YouTubeFailure.classify("KeyError: 'x'") == .other)
        #expect(YouTubeFailure.isRateLimited("HTTP Error 429: Too Many Requests"))
        #expect(YouTubeFailure.cookiesRejected(warnings: "WARNING: The provided YouTube account cookies are no longer valid"))
        #expect(!YouTubeFailure.cookiesRejected(warnings: "WARNING: ffmpeg not found"))
        #expect(YouTubeFailure.classify(StandaloneError.auth) == .auth)
        #expect(ChannelChecker.isRateLimit(StandaloneError.server(503)))
        #expect(ChannelChecker.isRateLimit(StowError.server("ERROR: HTTP Error 429: Too Many Requests")))
        #expect(!ChannelChecker.isRateLimit(StandaloneError.server(404)))
    }

    @Test func watchSyncNewlyWatched() throws {
        #expect(WatchSync.newlyWatched(history: ["a", "b", "c"], previous: []) == ["a", "b", "c"])
        #expect(WatchSync.newlyWatched(history: ["x", "y", "a", "b"], previous: ["a", "b"]) == ["x", "y"])
        // The newest anchor is gone (deleted from history): the next one counts.
        #expect(WatchSync.newlyWatched(history: ["x", "b", "c"], previous: ["a", "b", "c"]) == ["x"])
        #expect(WatchSync.newlyWatched(history: ["x"], previous: ["q"]) == ["x"])
        #expect(try WatchSync.parseHistory(#"{"entries":[{"id":"a"},{"id":"b"},{"id":"a"},null]}"#) == ["a", "b"])
    }
}

@Suite struct SubscriptionsTests {
    @Test func parsesTheFirstPage() throws {
        let html = try fixture("feed-channels.html")
        let data = try #require(SubscriptionsImport.initialData(html))
        let page = try SubscriptionsParser.parse(data)
        #expect(page.channels == [
            ChannelInfo(id: "UCtestchannel00000000001", title: "Test Channel", handle: "@TestChannel", avatarURL: "https://yt3.ggpht.com/big=s176"),
            ChannelInfo(id: "UCsecondchannel000000002", title: "Second Channel", handle: "@second.one", avatarURL: "https://yt3.ggpht.com/second=s176"),
        ])
        #expect(page.continuation == "PAGE-2-TOKEN")
        let config = SubscriptionsImport.config(html)
        #expect(config["INNERTUBE_CLIENT_VERSION"] as? String == "2.20261120.01.00")
        #expect(config["DELEGATED_SESSION_ID"] as? String == "fake-page-id")
        #expect((config["INNERTUBE_CONTEXT"] as? [String: Any])?["client"] != nil)
        let next = try SubscriptionsParser.parse(Data(try fixture("feed-channels-page2.json").utf8))
        #expect(next.channels.first?.handle == "@テスト")
        #expect(next.continuation == nil)
    }

    @Test func sapisidHash() {
        // printf '1700000000 fake/fake https://www.youtube.com' | shasum
        #expect(SubscriptionsImport.sapisidHash(sid: "fake/fake", timestamp: 1_700_000_000)
                == "1700000000_40f8e44cc9e163a1c8d600a1f514340e39cf21f8")
        #expect(SubscriptionsImport.sapisidHash(sid: "abc", timestamp: 1) == "1_76945995212dc850298a9feccea18a02639c6f64")
    }

    @Test func authorizationHeaders() throws {
        let cookies = NetscapeCookies.parse(try fixture("fake-cookies.txt"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let header = try #require(SubscriptionsImport.authorization(cookies: cookies, now: now))
        let hash = SubscriptionsImport.sapisidHash(sid: "fake/fake", timestamp: 1_700_000_000)
        #expect(header == "SAPISIDHASH \(hash) SAPISID3PHASH \(hash)")
        let headers = SubscriptionsImport.headers(config: ["SESSION_INDEX": 0, "INNERTUBE_CONTEXT_CLIENT_NAME": 1,
                                                           "INNERTUBE_CLIENT_VERSION": "2.1", "DELEGATED_SESSION_ID": "page"],
                                                  cookies: cookies, now: now)
        #expect(headers["X-Goog-AuthUser"] == "0")
        #expect(headers["X-Youtube-Client-Name"] == "1")
        #expect(headers["X-Youtube-Client-Version"] == "2.1")
        #expect(headers["X-Goog-PageId"] == "page")
        #expect(headers["X-Origin"] == "https://www.youtube.com")
        #expect(headers["Origin"] == "https://www.youtube.com")
        #expect(headers["Content-Type"] == "application/json")
    }

    @Test func fetchesEveryPage() async throws {
        let html = try fixture("feed-channels.html")
        let page2 = try fixture("feed-channels-page2.json")
        let server = StubServer { request in
            if request.path == "/feed/channels" { return (200, html) }
            if request.path == "/youtubei/v1/browse" { return (200, page2) }
            return (404, "")
        }
        let cookies = NetscapeCookies.parse(try fixture("fake-cookies.txt"))
        let channels = try await SubscriptionsImport(web: YouTubeWeb(session: server.session)).fetch(cookies: cookies)
        #expect(channels.map(\.id) == ["UCtestchannel00000000001", "UCsecondchannel000000002", "UCthirdchannel0000000003"])
        let browse = try #require(server.requests.first { $0.path == "/youtubei/v1/browse" })
        #expect(browse.method == "POST")
        #expect(browse.json["continuation"] as? String == "PAGE-2-TOKEN")
        #expect(browse.headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
        #expect(browse.headers["Cookie"]?.contains("LOGIN_INFO=FAKE") == true)
        let first = try #require(server.requests.first)
        #expect(first.headers["Cookie"]?.contains("SOCS=CAI") == true)
    }

    @Test func aSignInPageMeansExpired() async throws {
        let server = StubServer { _ in (200, "<html>no data</html>") }
        await #expect(throws: StandaloneError.auth) {
            _ = try await SubscriptionsImport(web: YouTubeWeb(session: server.session)).fetch(cookies: [])
        }
    }

    @Test func importSelectionStartsEmpty() {
        let channels = [ChannelInfo(id: "UCa", title: "A"), ChannelInfo(id: "UCb", title: "B"), ChannelInfo(id: "UCc", title: "C")]
        var selection = ImportSelection(channels: channels, followed: ["UCb"])
        #expect(selection.picked.isEmpty)
        #expect(selection.toAdd.isEmpty)
        #expect(selection.isPicked("UCb") && selection.isAdded("UCb"))
        selection.toggle("UCb")
        #expect(selection.isPicked("UCb"))
        #expect(selection.toAdd.isEmpty)
        selection.toggle("UCc")
        #expect(selection.toAdd.map(\.id) == ["UCc"])
        selection.selectAll()
        #expect(selection.toAdd.map(\.id) == ["UCa", "UCc"])
        selection.selectNone()
        #expect(selection.toAdd.isEmpty)
    }
}

@Suite struct CheckPlanTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ids = ["UCa", "UCb"]

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func plan(_ trigger: CheckTrigger, fetched: [String: FeedTimes] = [:], state: AccountState = .signedOut,
                      skipped: Set<String> = [], account: CheckPlan.Account? = nil) -> CheckPlan {
        CheckPlan.plan(trigger: trigger, channels: ids, fetchedAt: fetched, account: account ?? .init(state: state),
                       skippedMembers: skipped, now: now)
    }

    @Test func uploadsEveryCheckStreamsEverySixHours() {
        let fresh = ["UCa": FeedTimes(uploads: ago(60), streams: ago(3600)), "UCb": FeedTimes(streams: ago(7 * 3600))]
        for trigger in [CheckTrigger.launch, .foreground, .tick] {
            let p = plan(trigger, fetched: fresh)
            #expect(p.feeds("UCa") == .init(uploads: true, streams: false, members: false))
            #expect(p.feeds("UCb") == .init(uploads: true, streams: true, members: false))
            #expect(!p.accountFeeds && !p.history && !p.accessChecks)
        }
        // Never fetched: streams too.
        #expect(plan(.launch).feeds("UCa")?.streams == true)
        // Pull: streams an hour after the last read.
        let pull = plan(.pull, fetched: ["UCa": FeedTimes(streams: ago(30 * 60)), "UCb": FeedTimes(streams: ago(61 * 60))])
        #expect(pull.feeds("UCa")?.streams == false)
        #expect(pull.feeds("UCb")?.streams == true)
        // A new channel: everything.
        #expect(plan(.channelAdded, fetched: fresh).feeds("UCa")?.streams == true)
    }

    @Test func membersNeedASignIn() {
        let fetched = ["UCa": FeedTimes(members: ago(30 * 60)), "UCb": FeedTimes(members: ago(61 * 60))]
        #expect(plan(.launch, fetched: fetched).channels.allSatisfy { !$0.feeds.members })
        let signedIn = plan(.launch, fetched: fetched, state: .signedIn)
        #expect(signedIn.feeds("UCa")?.members == false)
        #expect(signedIn.feeds("UCb")?.members == true)
        #expect(signedIn.accessChecks)
        let pull = plan(.pull, fetched: ["UCa": FeedTimes(members: ago(10 * 60)), "UCb": FeedTimes(members: ago(16 * 60))], state: .signedIn)
        #expect(pull.feeds("UCa")?.members == false)
        #expect(pull.feeds("UCb")?.members == true)
        #expect(plan(.channelAdded, fetched: fetched, state: .signedIn).feeds("UCa")?.members == true)
        #expect(plan(.signIn, fetched: fetched, state: .signedIn).feeds("UCa")?.members == true)
        // Not a member, or no members playlist: skipped.
        #expect(plan(.signIn, fetched: fetched, state: .signedIn, skipped: ["UCa"]).feeds("UCa")?.members == false)
        // Expired: nothing that needs the sign-in.
        let expired = plan(.pull, state: .expired, account: .init(state: .expired, pendingMarks: true))
        #expect(expired.channels.allSatisfy { !$0.feeds.members })
        #expect(!expired.accountFeeds && !expired.history && !expired.accessChecks)
    }

    @Test func homeAndSubscriptionsAndHistory() {
        let recent = CheckPlan.Account(state: .signedIn, lastWatchSync: ago(5 * 60), feedsLoadedAt: ago(10 * 60))
        let stale = CheckPlan.Account(state: .signedIn, lastWatchSync: ago(16 * 60), feedsLoadedAt: ago(21 * 60))
        #expect(!plan(.foreground, account: recent).accountFeeds)
        #expect(plan(.foreground, account: stale).accountFeeds)
        #expect(plan(.tick, account: stale).accountFeeds)
        #expect(plan(.pull, account: recent).accountFeeds)
        #expect(plan(.signIn, account: recent).accountFeeds)
        #expect(!plan(.channelAdded, account: stale).accountFeeds)
        #expect(!plan(.launch, account: recent).history)
        #expect(plan(.launch, account: stale).history)
        #expect(plan(.pull, account: recent).history)
        var pending = recent
        pending.pendingMarks = true
        #expect(plan(.tick, account: pending).history)
        var off = stale
        off.syncWatched = false
        #expect(!plan(.pull, account: off).history)
    }

    @Test func theBackgroundRunIsTheRSSRoundAndADueSync() {
        let stale = CheckPlan.Account(state: .signedIn, lastWatchSync: ago(16 * 60), feedsLoadedAt: ago(3 * 3600))
        let background = plan(.background, account: stale)
        #expect(background.channels.allSatisfy { $0.feeds == .init(uploads: true, streams: false, members: false) })
        #expect(!background.accountFeeds)
        #expect(!background.accessChecks)
        #expect(background.history)
        let notDue = plan(.background, account: .init(state: .signedIn, lastWatchSync: ago(60)))
        #expect(!notDue.history)
    }

    private func record(started: TimeInterval, finished: TimeInterval, offline: Bool = false) -> CheckRecord {
        CheckRecord(trigger: "tick", startedAt: ago(started), finishedAt: ago(finished), channelsChecked: 2, errors: [], offline: offline)
    }

    @Test func dueAndBackoff() {
        func due(_ last: CheckRecord?, _ trigger: CheckTrigger = .tick, backoff: Date? = nil) -> Bool {
            CheckPlan.isDue(trigger: trigger, last: last, backoffUntil: backoff, now: now)
        }
        #expect(due(nil))
        // Measured from when the last check started, less a minute: a check that took two
        // minutes doesn't push the next one back a whole tick.
        #expect(due(record(started: 14 * 60, finished: 12 * 60)))
        #expect(!due(record(started: 14 * 60 - 10, finished: 14 * 60 - 20)))
        #expect(due(record(started: 15 * 60, finished: 15 * 60)))
        #expect(CheckPlan.dueSlack == 60)
        #expect(!due(record(started: 3600, finished: 3600), backoff: now.addingTimeInterval(60)))
        // A check that couldn't reach YouTube doesn't count; backoff still does.
        #expect(due(record(started: 60, finished: 30, offline: true)))
        #expect(!due(record(started: 60, finished: 30, offline: true), backoff: now.addingTimeInterval(60)))
        // Pull, a new channel and a sign-in run whatever the schedule.
        for trigger in [CheckTrigger.pull, .channelAdded, .signIn] {
            #expect(due(record(started: 60, finished: 30), trigger, backoff: now.addingTimeInterval(60)))
        }
        for trigger in [CheckTrigger.launch, .foreground, .tick, .background] {
            #expect(!due(record(started: 60, finished: 30), trigger))
        }
        #expect(CheckPlan.nextBackoff(previousMinutes: 0) == 30)
        #expect(CheckPlan.nextBackoff(previousMinutes: 30) == 60)
        #expect(CheckPlan.nextBackoff(previousMinutes: 120) == 240)
        #expect(CheckPlan.nextBackoff(previousMinutes: 240) == 240)
        let skipped = CheckPlan.skippedMembers(nonMember: ["UCa": ago(86_400), "UCb": ago(8 * 86_400)], noPlaylist: ["UCc": ago(60)], now: now)
        #expect(skipped == ["UCa", "UCc"])
    }

    @Test func lastReadIsTheLaterOfTheCheckAndTheNewestRead() {
        var state = StandaloneState()
        #expect(CheckStatus.lastReadAt(state) == nil)
        state.channels = [FollowedChannel(id: "UCa", title: "A"), FollowedChannel(id: "UCb", title: "B")]
        #expect(CheckStatus.lastReadAt(state) == nil)
        state.lastCheck = record(started: 3600, finished: 3500)
        #expect(CheckStatus.lastReadAt(state) == ago(3500))
        // A channel's first fetch (a seed), or the Mac's channels adopted, after the check.
        state.fetchedAt = ["UCa": FeedTimes(uploads: ago(600)), "UCb": FeedTimes(uploads: ago(4000), streams: ago(60))]
        #expect(CheckStatus.lastReadAt(state) == ago(600))
        // Unfollowed channels, past streams and a check that couldn't reach YouTube don't count.
        state.fetchedAt["UCgone"] = FeedTimes(uploads: ago(10))
        state.lastCheck = record(started: 120, finished: 100, offline: true)
        #expect(CheckStatus.lastReadAt(state) == ago(600))
        // Android's 0 is "never".
        state.fetchedAt = ["UCa": FeedTimes(uploads: Date(timeIntervalSince1970: 0))]
        #expect(CheckStatus.lastReadAt(state) == nil)

        let status = { (state: StandaloneState) in
            CheckStatus(isChecking: false, lastCheck: state.lastCheck, channelErrors: [:], backoffUntil: nil, failedCheckStreak: 0,
                        channelCount: state.channels.count, lastReadAt: CheckStatus.lastReadAt(state))
        }
        #expect(status(state).couldntReachYouTube)
        state.fetchedAt = ["UCa": FeedTimes(uploads: ago(50))]
        #expect(!status(state).couldntReachYouTube)
        state.lastCheck = record(started: 20, finished: 10)
        #expect(!status(state).couldntReachYouTube)
    }
}

@Suite struct MergeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let channel = FollowedChannel(id: "UCa", title: "Mine")

    private func video(_ id: String, days: Double?, title: String? = nil, members: Bool = false) -> Video {
        Video(id: id, channelId: "UCfeed", channelTitle: "Feed's name", title: title ?? id,
              publishedAt: days.map { now.addingTimeInterval(-$0 * 86_400) }, thumbnailURL: nil, isMembersOnly: members)
    }

    @Test func capsReplacesAndStampsUndated() {
        let stored = (1...30).map { StoredVideo(video("old\(String(format: "%08d", $0))", days: Double($0)), foundAt: now.addingTimeInterval(-86_400 * 40)) }
        let fresh = [video("old00000001", days: 1, title: "Renamed"), video("new00000001", days: 0.5), video("undated0001", days: nil)]
        let merged = RecentMerge.merge(stored, with: fresh, now: now, cap: 30)
        #expect(merged.count == 30)
        #expect(merged.first?.id == "undated0001")
        #expect(merged.first?.publishedAt == now)
        #expect(merged.first?.foundAt == now)
        #expect(merged[1].id == "new00000001")
        #expect(merged.first { $0.id == "old00000001" }?.title == "Renamed")
        // The oldest two dropped out at the cap.
        #expect(!merged.contains { $0.id == "old00000030" || $0.id == "old00000029" })
        // Seen again undated: keeps its first date.
        let later = RecentMerge.merge(merged, with: [video("undated0001", days: nil)], now: now.addingTimeInterval(3600), cap: 30)
        #expect(later.first { $0.id == "undated0001" }?.publishedAt == now)
    }

    @Test func approximateDatesNeverReplaceAKnownOne() {
        let precise = now.addingTimeInterval(-3 * 86_400 - 4321)
        let stored = [StoredVideo(Video(id: "rss00000001", channelId: "UCa", channelTitle: "Mine", title: "From RSS",
                                        publishedAt: precise, thumbnailURL: nil, isMembersOnly: false), foundAt: now)]
        // The Videos tab (RSS down): its rounded date doesn't move the known one; a new video takes its own.
        let tab = [video("rss00000001", days: 3, title: "Renamed"), video("tab00000001", days: 2)]
        let merged = RecentMerge.merge(stored, with: tab, now: now, cap: 30, approximate: ["rss00000001", "tab00000001"])
        #expect(merged.first { $0.id == "rss00000001" }?.publishedAt == precise)
        #expect(merged.first { $0.id == "rss00000001" }?.title == "Renamed")
        #expect(merged.first { $0.id == "tab00000001" }?.publishedAt == now.addingTimeInterval(-2 * 86_400))
        // Checked again with the tab: still the same dates.
        let again = RecentMerge.merge(merged, with: [video("tab00000001", days: 30)], now: now, cap: 30, approximate: ["tab00000001"])
        #expect(again.first { $0.id == "tab00000001" }?.publishedAt == now.addingTimeInterval(-2 * 86_400))
        // RSS back: its date wins.
        let exact = now.addingTimeInterval(-2 * 86_400 - 999)
        var fromRSS = video("tab00000001", days: nil)
        fromRSS.publishedAt = exact
        let fixed = RecentMerge.merge(again, with: [fromRSS], now: now, cap: 30)
        #expect(fixed.first { $0.id == "tab00000001" }?.publishedAt == exact)
    }

    @Test func approximateDatesKeepTheListedOrder() {
        // yt-dlp's "1 month ago" for four videos in a row: one date, so the order was arbitrary.
        let listed = [video("tab00000001", days: 2), video("tab00000002", days: 30), video("tab00000003", days: 30),
                      video("tab00000004", days: nil), video("tab00000005", days: 30), video("tab00000006", days: 60)]
        let ordered = RecentMerge.inListedOrder(listed)
        let month = now.addingTimeInterval(-30 * 86_400)
        #expect(ordered.map(\.publishedAt) == [now.addingTimeInterval(-2 * 86_400), month, month.addingTimeInterval(-60), nil,
                                               month.addingTimeInterval(-120), now.addingTimeInterval(-60 * 86_400)])
        let merged = RecentMerge.merge([], with: ordered, now: now, cap: 30, approximate: Set(ordered.map(\.id)))
        #expect(merged.map(\.id) == ["tab00000004", "tab00000001", "tab00000002", "tab00000003", "tab00000005", "tab00000006"])
    }

    @Test func theChannelsNameWins() {
        let normalized = RecentMerge.normalized(video("a0000000001", days: 1), channel: channel)
        #expect(normalized.channelId == "UCa")
        #expect(normalized.channelTitle == "Mine")
    }

    @Test func membersOnlyHiddenUntilWatchable() {
        let videos = [video("pub00000001", days: 1), video("mem00000001", days: 1, members: true),
                      video("mem00000002", days: 1, members: true), video("mem00000003", days: 1, members: true),
                      video("mem00000004", days: 1, members: true)]
        let access: [String: MemberAccess] = ["mem00000001": .watchable, "mem00000002": .nowPublic, "mem00000003": .locked(level: "Gold")]
        let visible = RecentMerge.visible(videos, access: { access[$0] })
        #expect(visible.map(\.id) == ["pub00000001", "mem00000001", "mem00000002"])
        #expect(visible[1].isMembersOnly)
        #expect(!visible[2].isMembersOnly)
    }
}

@Suite struct StandaloneStoreTests {
    @Test func roundTripsAndKeepsUnknownKeys() throws {
        let directory = temporaryDirectory()
        let store = StandaloneStore(directory: directory)
        #expect(store.load() == StandaloneState())
        var state = StandaloneState()
        state.channels = [FollowedChannel(id: "UCa", title: "A", handle: "@a", avatarURL: "https://a", addedAt: Date(timeIntervalSince1970: 1_700_000_000.123))]
        state.recentVideos["UCa"] = [StoredVideo(Video(id: "v0000000001", channelId: "UCa", channelTitle: "A", title: "T",
                                                       publishedAt: Date(timeIntervalSince1970: 1_700_000_000), thumbnailURL: nil,
                                                       isMembersOnly: true, liveStatus: "was_live", durationSeconds: 61),
                                                 foundAt: Date(timeIntervalSince1970: 1_700_000_001))]
        state.groups = [ChannelGroup(id: "g", name: "G", channels: [GroupChannel(id: "UCa", title: "A")])]
        state.memberAccess = ["v0000000001": MemberAccess.locked(level: "Gold").stored]
        state.account = StandaloneAccount(state: .signedIn, since: Date(timeIntervalSince1970: 1_700_000_000), source: .file)
        state.pendingYouTubeWatched = ["v0000000001"]
        state.backoffUntil = Date(timeIntervalSince1970: 1_700_000_500)
        state.channelErrors = ["UCb": "Channel not found"]
        store.save(state)

        // A newer build's field survives a save by this one.
        var raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
        raw["futureField"] = ["kept": true]
        try JSONSerialization.data(withJSONObject: raw).write(to: store.file)
        let reopened = StandaloneStore(directory: directory)
        var loaded = reopened.load()
        #expect(loaded.channels.first?.addedAt == Date(timeIntervalSince1970: 1_700_000_000.123))
        #expect(loaded.recentVideos["UCa"]?.first?.liveStatus == "wasLive")
        #expect(loaded.recentVideos["UCa"]?.first?.video.isPastStream == true)
        #expect(loaded.access("v0000000001") == .locked(level: "Gold"))
        #expect(loaded.account.source == .file)
        #expect(loaded.groups == state.groups)
        loaded.failedCheckStreak = 2
        reopened.save(loaded)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(text.contains("\"futureField\""))
        #expect(text.contains("\"addedAt\":1700000000123"))
        #expect(text.contains("\"publishedAt\":1700000000000"))
        #expect(!text.contains("cookies"))
        #expect(StandaloneStore(directory: directory).load().failedCheckStreak == 2)
    }

    @Test func anOfflineCheckIsSavedOnlyWhenTrue() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let online = CheckRecord(trigger: "tick", startedAt: at, finishedAt: at, channelsChecked: 3, errors: [])
        let text = String(decoding: try StandaloneStore.encoder.encode(online), as: UTF8.self)
        #expect(!text.contains("offline"))
        var offline = online
        offline.offline = true
        let offlineText = String(decoding: try StandaloneStore.encoder.encode(offline), as: UTF8.self)
        #expect(offlineText.contains("\"offline\":true"))
        #expect(try StandaloneStore.decoder.decode(CheckRecord.self, from: Data(offlineText.utf8)) == offline)
        // Written before the flag (or by Android when false): not offline.
        let older = #"{"trigger":"launch","startedAt":1700000000000,"finishedAt":1700000001000,"channelsChecked":2,"errors":["x"]}"#
        let decoded = try StandaloneStore.decoder.decode(CheckRecord.self, from: Data(older.utf8))
        #expect(!decoded.offline)
        #expect(decoded.errors == ["x"])
        #expect(decoded.finishedAt == Date(timeIntervalSince1970: 1_700_000_001))
    }

    @Test func readsWhatAndroidWrites() throws {
        let json = #"""
        {"version":1,"channels":[{"id":"UCa","title":"A","handle":null,"avatarURL":null,"addedAt":0}],
         "fetchedAt":{"UCa":{"uploads":1700000000000,"streams":0,"members":0}},
         "recentVideos":{"UCa":[{"id":"v0000000001","channelId":"UCa","channelTitle":"A","title":"T","publishedAt":1700000000000,
            "thumbnailURL":null,"isMembersOnly":false,"liveStatus":"none","duration":null,"foundAt":1700000000000}]},
         "account":{"state":"expired","since":1700000000000,"source":"web","lastProbeAt":0},
         "syncWatchedWithYouTube":false,"memberAccess":{"x":"nowPublic"}}
        """#
        let state = try StandaloneStore.decoder.decode(StandaloneState.self, from: Data(json.utf8))
        #expect(state.channels.map(\.id) == ["UCa"])
        #expect(state.fetchedAt["UCa"]?.uploads == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(state.recentVideos["UCa"]?.first?.video.liveStatus == nil)
        #expect(state.account.state == .expired)
        #expect(!state.syncWatchedWithYouTube)
        #expect(state.access("x") == .nowPublic)
    }
}
