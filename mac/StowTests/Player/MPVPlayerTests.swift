import Foundation
import Testing
@testable import Stow

struct MPVPlayerTests {
    private let ytdlp = URL(filePath: "/opt/homebrew/bin/yt-dlp")

    private func pairs(_ options: [(String, String)]) -> [String] {
        options.map { "\($0.0)=\($0.1)" }
    }

    @Test func optionsForAlarm() {
        let options = pairs(MPVPlayer.options(socketPath: "/tmp/s/mpv.sock", ytdlp: ytdlp,
                                              outputDeviceUID: "40-C1-F6-88-8F-AF:output",
                                              cookiesCopy: URL(filePath: "/x/cookie-copies/1.txt"), drawsVideo: true))
        for expected in ["config=no", "idle=once", "keep-open=no", "vo=libmpv", "input-default-bindings=no",
                         "volume=100", "input-ipc-server=/tmp/s/mpv.sock",
                         "script-opts=ytdl_hook-ytdl_path=/opt/homebrew/bin/yt-dlp",
                         "ytdl-format=bv*[height<=1080][fps<=60]+ba/b",
                         "audio-device=coreaudio/40-C1-F6-88-8F-AF:output",
                         "ytdl-raw-options=cookies=/x/cookie-copies/1.txt"] {
            #expect(options.contains(expected), "missing \(expected)")
        }
    }

    @Test func defaultOutputNoCookiesNoVideo() {
        let options = pairs(MPVPlayer.options(socketPath: "/s", ytdlp: ytdlp, outputDeviceUID: nil, cookiesCopy: nil,
                                              drawsVideo: false))
        #expect(options.contains("vo=null"))
        #expect(!options.contains { $0.hasPrefix("audio-device") || $0.hasPrefix("ytdl-raw-options") })
    }

    @Test func parsesCommandLineStyleOptions() {
        #expect(MPVPlayer.option(fromArgument: "--length=3")! == ("length", "3"))
        #expect(MPVPlayer.option(fromArgument: "--script-opts=a=b")! == ("script-opts", "a=b"))
        #expect(MPVPlayer.option(fromArgument: "--no-config")! == ("config", "no"))
        #expect(MPVPlayer.option(fromArgument: "--fs")! == ("fs", "yes"))
        #expect(MPVPlayer.option(fromArgument: "length") == nil)
    }

    @Test func emptyPlaylistThrows() async {
        await #expect(throws: StowError.player("Nothing to play.")) {
            _ = try await MPVPlayer().play(playlist: [], outputDeviceUID: nil, cookiesFile: nil)
        }
    }
}

/// Streams a real YouTube video through mpv with no video or audio output. Needs the network,
/// so it only runs with `TEST_RUNNER_STOW_MPV_TESTS=1 xcodebuild test …`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STOW_MPV_TESTS"] != nil), .serialized)
struct MPVPlayerLiveTests {
    private static let silent = ["--vo=null", "--ao=null"]
    private let entry = PlayableVideo(video: video("-tCjS49NmyU"), duration: nil)

    private func cookiesFile() throws -> URL {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "cookies.txt")
        try Data("# Netscape HTTP Cookie File\n".utf8).write(to: file)
        return file
    }

    private func copies(of cookies: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: CookieCopy.directory(for: cookies).path)) ?? []
    }

    @Test func playsToTheEnd() async throws {
        let cookies = try cookiesFile()
        let player = MPVPlayer(extraArguments: Self.silent + ["--length=3"])
        let stream = try await player.play(playlist: [entry], outputDeviceUID: nil, cookiesFile: cookies)
        #expect(copies(of: cookies).count == 1)
        var events: [PlayerEvent] = []
        for await event in stream { events.append(event) }

        #expect(events.first == .started(index: 0, videoId: "-tCjS49NmyU"))
        guard case .videoEnded("-tCjS49NmyU", let position, let duration) = events.dropLast().last else {
            Issue.record("no videoEnded in \(events)")
            return
        }
        #expect(position > 2 && position < 4)
        #expect((duration ?? 0) > 60)
        #expect(events.last == .exited(.finished))
        #expect(copies(of: cookies).isEmpty)
    }

    @Test func stopEndsTheRunAndCleansUp() async throws {
        let cookies = try cookiesFile()
        let player = MPVPlayer(extraArguments: Self.silent)
        let stream = try await player.play(playlist: [entry, entry], outputDeviceUID: nil, cookiesFile: cookies)
        var events: [PlayerEvent] = []
        for await event in stream {
            events.append(event)
            if case .started = event {
                try await Task.sleep(for: .seconds(2))
                await player.stop()
            }
        }
        #expect(events.first == .started(index: 0, videoId: "-tCjS49NmyU"))
        #expect(events.contains { if case .videoEnded(_, let position, _) = $0 { position > 1 } else { false } })
        #expect(events.last == .exited(.stopped))
        #expect(copies(of: cookies).isEmpty)
        await player.stop()
    }

    @Test func unavailableVideoFails() async throws {
        let player = MPVPlayer(extraArguments: Self.silent)
        let missing = PlayableVideo(video: video("xxxxxxxxxxx"), duration: nil)
        var events: [PlayerEvent] = []
        for await event in try await player.play(playlist: [missing], outputDeviceUID: nil, cookiesFile: nil) {
            events.append(event)
        }
        guard case .loadFailed("xxxxxxxxxxx", let message) = events.first, case .exited(.failed) = events.last else {
            Issue.record("unexpected \(events)")
            return
        }
        #expect(message.contains("unavailable"))
    }
}
