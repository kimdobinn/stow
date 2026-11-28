import Foundation
import StowKit
import Testing
@testable import Stow

/// The app's side of standalone mode: the new yt-dlp ops, the screens' routing by mode, and the
/// sign-in's user agent. Nothing here reaches YouTube or Firebase.
@Suite struct FlatListingTests {
    @Test func parsesTheFlatOpsAnswer() throws {
        let answer = #"{"info":{"_type":"playlist","id":"UULV","entries":[{"id":"abc","live_status":"was_live"}]},"cookiesRejected":true}"#
        let listing = try YtDlpFlatListing.parse(Data(answer.utf8))
        #expect(listing.cookiesRejected)
        let info = try #require(try JSONSerialization.jsonObject(with: listing.json) as? [String: Any])
        #expect((info["entries"] as? [[String: Any]])?.first?["id"] as? String == "abc")
        #expect(try YtDlpFlatListing.parse(Data(#"{"info":{},"cookiesRejected":false}"#.utf8)).cookiesRejected == false)
        #expect(throws: YtDlpError.self) { try YtDlpFlatListing.parse(Data(#"{"info":null}"#.utf8)) }
    }

    @Test func theToolPassesListingsThrough() async throws {
        var fake = FakeYtDlp()
        fake.flatJSON[":ytsubs"] = Data(#"{"entries":[{"id":"aaaaaaaaaaa","title":"Sub","channel_id":"UCx","duration":300}]}"#.utf8)
        let tool = YtDlpTool(ytdlp: fake)
        let listing = try await tool.flatListing(":ytsubs", count: 150, cookies: URL(filePath: "/tmp/none.txt"))
        #expect(!listing.cookiesRejected)
        #expect(try YouTubeListing.parse(listing.json).map(\.id) == ["aaaaaaaaaaa"])
        fake.cookiesRejected = true
        let rejected = try await YtDlpTool(ytdlp: fake).flatListing(":ytsubs", count: 1, cookies: URL(filePath: "/tmp/none.txt"))
        #expect(rejected.cookiesRejected)
        // Without cookies there's nothing to reject.
        #expect(try await YtDlpTool(ytdlp: fake).flatListing(":ytsubs", count: 1, cookies: nil).cookiesRejected == false)
        try await YtDlpTool(ytdlp: FakeYtDlp()).markWatched(videoId: "aaaaaaaaaaa", cookies: URL(filePath: "/tmp/none.txt"))
        await #expect(throws: YtDlpError.self) {
            try await YtDlpTool(ytdlp: fake).markWatched(videoId: "aaaaaaaaaaa", cookies: URL(filePath: "/tmp/none.txt"))
        }
    }

    /// The real interpreter knows both ops (an input that isn't a URL fails before any network).
    @Test func pythonHasTheNewOps() async throws {
        for op in ["flat", "mark_watched"] {
            do {
                _ = try await PythonRuntime.shared.call(["op": op, "url": "notaurl", "count": 1])
                Issue.record("\(op) should fail on a non-URL")
            } catch let error as YtDlpError {
                let message = error.errorDescription ?? ""
                #expect(!message.contains("unknown request"), "\(op): \(message)")
                #expect(message.localizedCaseInsensitiveContains("url"), "\(op): \(message)")
            }
        }
    }
}

@Suite struct SignInTests {
    @Test func looksLikeMobileSafari() {
        #expect(SignInView.applicationName(systemVersion: "26.1") == "Version/26.1 Mobile/15E148 Safari/604.1")
        #expect(SignInView.applicationName(systemVersion: "17") == "Version/17.0 Mobile/15E148 Safari/604.1")
        #expect(SignInView.applicationName(systemVersion: "18.6.2") == "Version/18.6 Mobile/15E148 Safari/604.1")
    }

    @Test func spotsGooglesRefusal() {
        #expect(SignInView.isBlocked(url: URL(string: "https://accounts.google.com/v3/signin/rejected?x=1"), title: nil))
        #expect(SignInView.isBlocked(url: URL(string: "https://accounts.google.com/signin/rejected"), title: nil))
        #expect(SignInView.isBlocked(url: nil, title: "This browser or app may not be secure"))
        #expect(!SignInView.isBlocked(url: URL(string: "https://accounts.google.com/v3/signin/identifier"), title: "Sign in - Google Accounts"))
        #expect(SignInView.loginURL.absoluteString == "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/")
    }

    @Test func doneOnlyForANewSession() {
        // The Mac's rule: youtube.com, loaded, with a session.
        #expect(SignInView.isSignedIn(host: "www.youtube.com", isLoading: false, fingerprint: "a", before: nil))
        #expect(SignInView.isSignedIn(host: "m.youtube.com", isLoading: false, fingerprint: "a", before: nil))
        #expect(!SignInView.isSignedIn(host: "www.youtube.com", isLoading: true, fingerprint: "a", before: nil))
        #expect(!SignInView.isSignedIn(host: "accounts.google.com", isLoading: false, fingerprint: "a", before: nil))
        #expect(!SignInView.isSignedIn(host: "www.youtube.com", isLoading: false, fingerprint: nil, before: nil))
        // After YouTube refused one: that session doesn't count again, a new one does.
        #expect(!SignInView.isSignedIn(host: "www.youtube.com", isLoading: false, fingerprint: "a", before: "a"))
        #expect(SignInView.isSignedIn(host: "www.youtube.com", isLoading: false, fingerprint: "b", before: "a"))
    }

    @Test func accountRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let since = Date(timeIntervalSince1970: 1_796_256_000) // 3 Dec 2026
        #expect(AccountText.row(.signedOut) == "Not signed in. Optional: for Home, Subscriptions and members-only videos.")
        #expect(AccountText.row(StandaloneAccount(state: .expired)) == "YouTube signed you out. Sign in again.")
        let file = AccountText.row(StandaloneAccount(state: .signedIn, since: since, source: .file), calendar: calendar, locale: locale)
        #expect(file.hasPrefix("Signed in · since "))
        #expect(file.contains("Dec"))
        #expect(file.hasSuffix(" · from a cookies.txt file"))
        #expect(!AccountText.row(StandaloneAccount(state: .signedIn, since: since, source: .web)).contains("cookies.txt"))
    }

    @Test func checkStatusFooter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = CheckRecord(trigger: "tick", startedAt: now.addingTimeInterval(-250), finishedAt: now.addingTimeInterval(-240),
                                 channelsChecked: 23, errors: [])
        var status = CheckStatus(isChecking: false, lastCheck: record, channelErrors: [:], backoffUntil: nil, failedCheckStreak: 0,
                                 channelCount: 23, lastReadAt: record.finishedAt)
        #expect(AccountText.checkStatus(status, now: now) == "Checked 4 min ago · 23 channels")
        status.channelErrors = ["UCa": "Channel not found", "UCb": "Channel not found"]
        #expect(AccountText.checkStatus(status, now: now) == "Checked 4 min ago · 23 channels · 2 channels had errors")
        status.failedCheckStreak = 3
        status.lastCheck?.errors = ["A: uploads failed: offline"]
        #expect(AccountText.checkStatus(status, now: now) == "Checks are failing: A: uploads failed: offline")
    }

    @Test func checkStatusSaysWhenTheChannelsWereLastRead() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Only a seed (a channel just added): no check yet, but the channels were read.
        var status = CheckStatus(isChecking: false, lastCheck: nil, channelErrors: [:], backoffUntil: nil, failedCheckStreak: 0,
                                 channelCount: 1, lastReadAt: now.addingTimeInterval(-20))
        #expect(AccountText.checkStatus(status, now: now) == "Checked just now · 1 channel")
        // An hour-old check, then a seed 2 minutes ago.
        status.lastCheck = CheckRecord(trigger: "tick", startedAt: now.addingTimeInterval(-3_700), finishedAt: now.addingTimeInterval(-3_600),
                                       channelsChecked: 1, errors: [])
        status.lastReadAt = now.addingTimeInterval(-120)
        #expect(AccountText.checkStatus(status, now: now) == "Checked 2 min ago · 1 channel")
        status.lastReadAt = nil
        status.lastCheck = nil
        #expect(AccountText.checkStatus(status, now: now) == "Not checked yet")
        // Nothing followed.
        status.channelCount = 0
        #expect(AccountText.checkStatus(status, now: now) == "Add channels to check them for new videos")
        status.isChecking = true
        #expect(AccountText.checkStatus(status, now: now) == "Add channels to check them for new videos")
    }

    @Test func checkStatusSaysWhenYouTubeCouldntBeReached() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let offline = CheckRecord(trigger: "tick", startedAt: now.addingTimeInterval(-40), finishedAt: now.addingTimeInterval(-30),
                                  channelsChecked: 23, errors: ["A: uploads failed: offline"], offline: true)
        var status = CheckStatus(isChecking: false, lastCheck: offline, channelErrors: ["UCa": "Channel not found"], backoffUntil: nil,
                                 failedCheckStreak: 1, channelCount: 23, lastReadAt: now.addingTimeInterval(-3_600))
        #expect(AccountText.checkStatus(status, now: now) == "Couldn't reach YouTube just now · 23 channels")
        status.lastCheck?.finishedAt = now.addingTimeInterval(-600)
        #expect(AccountText.checkStatus(status, now: now) == "Couldn't reach YouTube 10 min ago · 23 channels")
        // Read since (a seed): that's what it says.
        status.lastReadAt = now.addingTimeInterval(-60)
        #expect(AccountText.checkStatus(status, now: now) == "Checked 1 min ago · 23 channels · 1 channel had errors")
        // Never read at all.
        status.lastReadAt = nil
        #expect(AccountText.checkStatus(status, now: now) == "Couldn't reach YouTube 10 min ago · 23 channels")
    }
}

/// The shell in standalone mode, on a repository with no Firebase and nothing followed.
@MainActor
@Suite struct StandaloneShellTests {
    let repository: Repository
    let shell: Shell

    init() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "standalone-shell-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "standalone-shell-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("standalone", forKey: "appMode")
        repository = Repository(config: nil, youtube: SlowYouTube(), defaults: defaults, directory: directory,
                                tokenStore: InMemoryTokenStore(), cookieVault: InMemoryCookieVault())
        shell = Shell(repository: repository)
    }

    @Test func routesByMode() {
        #expect(RootView.screen(mode: .choosing, paired: false) == .welcome)
        #expect(RootView.screen(mode: .mac, paired: false) == .pair)
        #expect(RootView.screen(mode: .mac, paired: true) == .app)
        #expect(RootView.screen(mode: .standalone, paired: false) == .app)
        #expect(repository.mode == .standalone)
        #expect(repository.remote == nil)
        #expect(repository.standalone != nil)
    }

    @Test func videoMenusCanFollow() {
        let actions = shell.actions
        #expect(actions.follow != nil)
        #expect(actions.marksAnyWatched)
        #expect(!actions.isFollowing("UCLA_DiR1FfKNvjuUpBHmylQ"))
        shell.follow("UCLA_DiR1FfKNvjuUpBHmylQ", title: "NASA")
        #expect(repository.followedIds == ["UCLA_DiR1FfKNvjuUpBHmylQ"])
        #expect(shell.actions.isFollowing("UCLA_DiR1FfKNvjuUpBHmylQ"))
        #expect(shell.toast?.message == "Following NASA")
        shell.unfollow("UCLA_DiR1FfKNvjuUpBHmylQ")
        #expect(repository.followedIds.isEmpty)
        #expect(shell.toast?.message == "Removed NASA")
    }

    @Test func refreshMessages() {
        #expect(Shell.refreshMessage(.done, mode: .standalone) == "Up to date")
        #expect(Shell.refreshMessage(.youtubeFailed, mode: .standalone) == "Couldn't reach YouTube. Check the connection.")
        #expect(Shell.refreshMessage(.slowedDown, mode: .standalone) == "YouTube asked Stow to slow down. It'll try again later.")
        #expect(Shell.refreshMessage(.failed, mode: .mac) == "Couldn't reach the Mac's Firebase. Check the connection.")
        #expect(Shell.refreshMessage(.noAnswer, mode: .mac) == "The Mac didn't answer. Is Stow running on it?")
    }

    @Test func launchRoutesOpenStandaloneScreens() {
        LaunchRoutes.apply(to: shell, repository: repository, arguments: ["Stow", "-open", "account,channels-manage,import,add-channel"])
        #expect(shell.homePath == [.account, .channelsManage, .importChannels])
        #expect(shell.addingChannel)
    }

    @Test func aMacModeShellHasNoFollow() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mac-shell-\(UUID().uuidString)")
        let suite = "mac-shell-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let demo = Repository(config: nil, youtube: SlowYouTube(), demo: true, defaults: defaults, directory: directory,
                              tokenStore: InMemoryTokenStore(), cookieVault: InMemoryCookieVault())
        let actions = Shell(repository: demo).actions
        #expect(actions.follow == nil)
        #expect(!actions.marksAnyWatched)
        #expect(demo.mode == .mac)
    }
}
