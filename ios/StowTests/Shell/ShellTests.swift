import Foundation
import StowKit
import Testing
@testable import Stow

/// The text under videos reads as on Android.
@Suite struct FormatTextTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let locale = Locale(identifier: "en_US")

    private func item(_ video: Video) -> VideoItem {
        VideoItem(video: video, sent: nil, local: nil, watchedOnMac: false)
    }

    private func video(published: Date?, live: String? = nil, members: Bool = false, seconds: Int? = nil) -> Video {
        Video(id: "v", channelId: "c", channelTitle: "Channel", title: "Title", publishedAt: published,
              thumbnailURL: nil, isMembersOnly: members, liveStatus: live, durationSeconds: seconds)
    }

    @Test func agoSaysItLikeYouTube() {
        func ago(_ seconds: TimeInterval) -> String { Format.ago(now.addingTimeInterval(-seconds), now: now) }
        #expect(ago(10) == "Just now")
        #expect(ago(60) == "1 minute ago")
        #expect(ago(5 * 60) == "5 minutes ago")
        #expect(ago(4 * 3600) == "4 hours ago")
        #expect(ago(3 * 86_400) == "3 days ago")
        #expect(ago(17 * 86_400) == "2 weeks ago")
        #expect(ago(100 * 86_400) == "3 months ago")
        #expect(ago(340 * 86_400) == "11 months ago")
        #expect(ago(364 * 86_400) == "1 year ago")
        #expect(ago(729 * 86_400) == "2 years ago")
        #expect(ago(3 * 365 * 86_400) == "3 years ago")
        #expect(Format.ago(nil, now: now) == "")
    }

    @Test func pastStreamsSayStreamed() {
        let streamed = item(video(published: now.addingTimeInterval(-3 * 86_400), live: "wasLive"))
        #expect(Format.whenText(streamed, now: now).hasPrefix("Streamed "))
        #expect(Format.whenText(streamed, now: now).contains("days ago"))
        let undated = item(video(published: nil, live: "was_live"))
        #expect(Format.whenText(undated, now: now) == "Streamed")
    }

    @Test func metaJoinsWhatIsKnown() {
        let members = item(video(published: nil, members: true, seconds: 252))
        #expect(Format.meta(members, now: now) == "Channel · Members only")
        #expect(Format.meta(members, withDuration: true, now: now) == "Channel · 4:12 · Members only")
        #expect(Format.metaWithoutChannel(members, now: now) == "Members only")
    }
}

/// Channel initials get the same color as on Android (Java's String.hashCode).
@Suite struct AvatarColorTests {
    @Test func hashMatchesJava() {
        // "jawed".hashCode() in Java.
        var hash: Int32 = 0
        for unit in "jawed".utf16 { hash = hash &* 31 &+ Int32(unit) }
        #expect(hash == 100_900_543)
        #expect(ChannelAvatar.color(for: "jawed") == ChannelAvatar.color(for: "jawed"))
        #expect(ChannelAvatar.color(for: "jawed") != ChannelAvatar.color(for: "Rick Astley"))
    }
}

/// StowKit's YouTubeTool on top of the app's yt-dlp.
@Suite struct YtDlpToolTests {
    private let video = Video(id: "aqz-KE-bpKQ", channelId: "c", channelTitle: "Blender", title: "Big Buck Bunny",
                              publishedAt: nil, thumbnailURL: nil, isMembersOnly: false)

    @Test func streamsHLSFirst() async throws {
        let stream = try await YtDlpTool(ytdlp: FakeYtDlp()).stream(video, cookies: nil)
        #expect(stream.url.pathExtension == "m3u8")
        #expect(stream.audioURL == nil)
    }

    @Test func capsQualityAt1080p() {
        #expect(YtDlpTool.maxHeight(.best) == 1080)
        #expect(YtDlpTool.maxHeight(.p1440) == 1080)
        #expect(YtDlpTool.maxHeight(.p720) == 720)
    }

    @Test func sizeIsThePlansEstimate() async throws {
        var fake = FakeYtDlp()
        fake.plannedBytes = 1234
        #expect(try await YtDlpTool(ytdlp: fake).downloadSize(video, cookies: nil, quality: .p720) == 1234)
    }

    @Test func listingsComeBackAsText() async throws {
        let json = try await YtDlpTool(ytdlp: FakeYtDlp()).search("bunny", count: 5)
        #expect(json.contains("Big Buck Bunny"))
        let videos = try YouTubeListing.parse(json)
        #expect(videos.map(\.id) == ["aqz-KE-bpKQ"])
    }

    @Test func errorsKeepYtDlpsMessage() async {
        var fake = FakeYtDlp()
        fake.failure = .failed("Video unavailable")
        do {
            _ = try await YtDlpTool(ytdlp: fake).info(videoId: "x", cookies: nil)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription == "Video unavailable")
        }
    }
}

/// Navigation, playing and the download size question, on a demo repository.
@MainActor
@Suite struct ShellTests {
    let repository: Repository
    let shell: Shell

    init() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "shell-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "shell-tests-\(UUID().uuidString)")!
        repository = Repository(config: nil, youtube: YtDlpTool(ytdlp: FakeYtDlp()), demo: true, defaults: defaults,
                                directory: directory, tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline))
        repository.start()
        shell = Shell(repository: repository)
    }

    @Test func routesGoOnTheCurrentTab() {
        shell.open(.search)
        #expect(shell.homePath == [.search])
        shell.select(.subscriptions)
        shell.open(.channels)
        #expect(shell.subscriptionsPath == [.channels])
        #expect(shell.homePath == [.search])
        // Tapping the tab you're on goes back to its first screen.
        shell.select(.subscriptions)
        #expect(shell.subscriptionsPath.isEmpty)
        shell.back()
        #expect(shell.subscriptionsPath.isEmpty)
    }

    @Test func openingAChannelShrinksThePlayer() throws {
        let item = try #require(repository.recommended.first)
        shell.play(item)
        #expect(shell.playback?.queue == [item.id])
        #expect(shell.playerExpanded)
        shell.openChannel(item.video.channelId)
        // Still playing, in the mini player.
        #expect(shell.playback?.queue == [item.id])
        #expect(!shell.playerExpanded)
        #expect(shell.homePath == [.channel(item.video.channelId)])
        shell.closePlayer()
        #expect(shell.playback == nil)
    }

    @Test func playsWithinTheGivenList() throws {
        let list = Array(repository.recommended.prefix(3))
        try #require(list.count == 3)
        shell.play(list, start: list[1])
        #expect(shell.playback?.queue == list.map(\.id))
        #expect(shell.playback?.startId == list[1].id)
        // Not in the list: plays on its own.
        let other = try #require(repository.subscriptionsFeed.first { item in !list.contains { $0.id == item.id } })
        shell.play(list, start: other)
        #expect(shell.playback?.queue == [other.id])
    }

    @Test func longVideosAskFirst() throws {
        let long = try #require(repository.everything.first { $0.durationMs >= Repository.longVideoMs })
        shell.actions.download(long)
        #expect(shell.sizing?.id == long.id)
        #expect(repository.item(long.id)?.state == nil)

        let short = try #require(repository.recommended.first { $0.durationMs < Repository.longVideoMs })
        shell.actions.download(short)
        #expect(repository.item(short.id)?.state == .queued)
        #expect(shell.toast?.message == "Downloading")
    }

    @Test func newGroupsComeFromTheGroupActions() {
        let group = shell.groupActions.create("Music", with: GroupChannel(id: "c1", title: "One"))
        #expect(repository.groups.map(\.name) == ["Music"])
        shell.groupActions.set(group.id, channel: GroupChannel(id: "c2", title: "Two"), included: true)
        #expect(repository.groups.first?.channels.map(\.id) == ["c1", "c2"])
        shell.groupActions.rename(group.id, to: "Songs")
        shell.groupActions.delete(group.id)
        #expect(repository.groups.isEmpty)
    }
}

/// The Keychain token store, inside the app (StowKit's own test can't reach the Keychain without a host app).
@Suite struct AppKeychainTests {
    @Test func savesReadsAndRemovesTheTokens() {
        let store = KeychainTokenStore(service: "dev.stow.ios.tests.\(UUID().uuidString)")
        #expect(store.load() == nil)
        let tokens = AuthTokens(uid: "uid", idToken: "id-token", refreshToken: "refresh-token",
                                expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        store.save(tokens)
        #expect(store.load() == tokens)
        store.save(nil)
        #expect(store.load() == nil)
    }
}
