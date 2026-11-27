import Foundation
import StowKit
import Testing
@testable import Stow

/// Search, its suggestions, playlists, Your week and the launch routes, on a demo repository.
@MainActor
@Suite struct ScreenTests {
    let repository: Repository
    let shell: Shell
    let tool: SlowYouTube

    init() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "screen-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "screen-tests-\(UUID().uuidString)")!
        tool = SlowYouTube()
        repository = Repository(config: nil, youtube: tool, demo: true, defaults: defaults,
                                directory: directory, tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline))
        repository.start()
        shell = Shell(repository: repository)
    }

    private func settle(_ model: SearchModel) async {
        for _ in 0..<200 where model.loading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func searchFindsVideosAndRemembersTheQuery() async {
        let model = SearchModel()
        model.run("bunny", repository: repository)
        #expect(model.loading)
        #expect(model.submitted == "bunny")
        await settle(model)
        #expect(model.error == nil)
        #expect(model.resultIds == [SlowYouTube.id("bunny", 1), SlowYouTube.id("bunny", 2)])
        // Results join the items, so they play and download like any video.
        #expect(repository.item(SlowYouTube.id("bunny", 1))?.video.title == "bunny 1")
        #expect(repository.prefs.recentSearches == ["bunny"])
    }

    @Test func aNewSearchReplacesTheOneUnderWay() async {
        let model = SearchModel()
        model.run("slow", repository: repository)
        model.run("fast", repository: repository)
        await settle(model)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.submitted == "fast")
        #expect(model.resultIds == [SlowYouTube.id("fast", 1), SlowYouTube.id("fast", 2)])
        #expect(model.error == nil)
        #expect(!model.loading)
        #expect(repository.prefs.recentSearches == ["fast"])
    }

    @Test func searchErrorsReadLikeYtDlp() async {
        let model = SearchModel()
        model.run("fail", repository: repository)
        await settle(model)
        #expect(model.error == "Unable to download API page: HTTP Error 429")
        #expect(model.resultIds.isEmpty)
        #expect(repository.prefs.recentSearches.isEmpty)
    }

    @Test func errorTextIsOneShortLine() {
        #expect(ErrorText.short(YtDlpError.failed("ERROR: This video is unavailable\nmore")) == "This video is unavailable")
        #expect(ErrorText.short(CancellationError()) == "Check the connection and try again.")
    }

    @Test func suggestionsMatchEveryWord() throws {
        let recent = ["Rick Astley live", "rick roll", "blender", "rick"]
        #expect(SearchSuggestions.pastSearches(recent, matching: "rick") == ["Rick Astley live", "rick roll"])
        #expect(SearchSuggestions.pastSearches(recent, matching: "live RICK") == ["Rick Astley live"])
        let yours = SearchSuggestions.yourVideos(repository.everything, matching: "astley together")
        #expect(yours.map(\.id) == ["yPYZpwSpKmA"])
        // By channel too.
        #expect(SearchSuggestions.yourVideos(repository.everything, matching: "JAWED").map(\.id) == ["jNQXAC9IVRw"])
        #expect(SearchSuggestions.yourVideos(repository.everything, matching: "  ").isEmpty)
    }

    @Test func playAllPrefersDownloads() throws {
        let streamed = try #require(repository.item("dQw4w9WgXcQ"))
        var downloaded = try #require(repository.item("yPYZpwSpKmA"))
        downloaded.local = LocalVideo(id: downloaded.id, state: .downloaded, fileName: "yPYZpwSpKmA.mp4")
        #expect(PlaylistScreen.playAllOrder([streamed, downloaded], shuffle: false).map(\.id) == [downloaded.id])
        // Nothing downloaded yet: all of them, streamed.
        #expect(PlaylistScreen.playAllOrder([streamed], shuffle: true).map(\.id) == [streamed.id])
        #expect(PlaylistScreen.playAllOrder([], shuffle: false).isEmpty)
    }

    @Test func weekReportComparesWithTheWeekBefore() {
        func day(_ key: String, _ seconds: [String: Int], finished: [String: Int] = [:]) -> WatchStats.Day {
            WatchStats.Day(key: key, secondsByChannel: seconds, finishedByChannel: finished)
        }
        let thisWeek = [day("2026-11-21", ["a": 600, "b": 1200]), day("2026-11-27", ["a": 3000], finished: ["a": 2])]
        let report = WeekReport(thisWeek: thisWeek, lastWeek: [day("2026-11-14", ["a": 1800])])
        #expect(report.total == 4800)
        #expect(report.byChannel.map(\.channelId) == ["a", "b"])
        #expect(report.byChannel.first?.finished == 2)
        #expect(report.change == "50 min more than the week before")
        #expect(WeekReport(thisWeek: [], lastWeek: []).change == "in the last 7 days")
        #expect(WeekReport(thisWeek: [], lastWeek: [day("2026-11-14", ["a": 120])]).change == "2 min less than the week before")
        #expect(WeekReport(thisWeek: [day("x", ["a": 5])], lastWeek: []).channelMax == 60)
    }

    @Test func launchRoutesOpenScreens() throws {
        let playlist = repository.createPlaylist("Mix")
        LaunchRoutes.apply(to: shell, repository: repository,
                           arguments: ["Stow", "-tab", "downloads", "-open", "settings,report,playlist:first,save:dQw4w9WgXcQ"])
        #expect(shell.tab == .downloads)
        #expect(shell.downloadsPath == [.settings, .report, .playlist(playlist.id)])
        #expect(shell.saving?.id == "dQw4w9WgXcQ")
    }
}

/// Answers searches after a moment ("slow" takes longer), and fails "fail" with a yt-dlp error.
nonisolated final class SlowYouTube: YouTubeTool, @unchecked Sendable {
    func search(_ query: String, count: Int) async throws -> String {
        try await Task.sleep(for: .milliseconds(query == "slow" ? 300 : 30))
        if query == "fail" { throw YtDlpError.failed("ERROR: Unable to download API page: HTTP Error 429") }
        let entries = (1...2).map { #"{"id":"\#(Self.id(query, $0))","title":"\#(query) \#($0)","channel":"C","channel_id":"UCc","duration":300}"# }
        return #"{"_type":"playlist","entries":[\#(entries.joined(separator: ","))]}"#
    }

    /// YouTube ids are 11 characters.
    static func id(_ query: String, _ n: Int) -> String {
        let base = "\(query)-\(n)"
        return base + String(repeating: "_", count: max(0, 11 - base.count))
    }

    func info(videoId: String, cookies: URL?) async throws -> String { "{}" }
    func channelTab(channelId: String, tab: ChannelTab, count: Int) async throws -> String { #"{"entries":[]}"# }
    func comments(videoId: String, cookies: URL?) async throws -> String { #"{"comments":[]}"# }
    func stream(_ video: Video, cookies: URL?) async throws -> StreamInfo { throw CancellationError() }
    func downloadSize(_ video: Video, cookies: URL?, quality: DownloadQuality) async throws -> Int64? { nil }
    func download(_ video: Video, cookies: URL?, quality: DownloadQuality, to directory: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL { throw CancellationError() }
    func cancel(videoId: String) {}
}
