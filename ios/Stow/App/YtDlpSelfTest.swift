import AVFoundation
import Foundation
import Observation
import os

/// Checks yt-dlp against real public YouTube videos: `Stow -ytdlp-selftest` (add `-ytdlp-nojs` to
/// skip JavaScriptCore, `-ytdlp-debug` for yt-dlp's verbose log, `-ytdlp-selftest-exit` to quit when done). Prints each step and writes
/// Documents/ytdlp-selftest.json. The debug screen runs the same steps.
@MainActor @Observable
final class YtDlpSelfTest {
    struct Step: Identifiable, Codable {
        var id: String { name }
        var name: String
        var passed: Bool
        var seconds: Double
        var detail: String
    }

    static let launchArgument = "-ytdlp-selftest"

    /// A 10-minute film with every format (Blender's Big Buck Bunny).
    static let infoVideo = "aqz-KE-bpKQ"
    /// An 18-second clip with a 480p H.264 format.
    static let downloadVideo = "C0DPdy98e4c"
    static let channel = "UCSMOQeBJ2RAnuFungnQOxLg"

    private(set) var steps: [Step] = []
    private(set) var running = false
    private let ytDlp: YtDlp
    private let log = Logger(subsystem: "dev.stow.ios", category: "selftest")

    init(ytDlp: YtDlp = .shared) {
        self.ytDlp = ytDlp
    }

    func run(javaScript: Bool = true, debug: Bool = false) async {
        guard !running else { return }
        running = true
        steps = []
        defer { running = false }
        let launched = ContinuousClock.now

        await step("start Python") {
            try await self.ytDlp.prepare()
            let startup = PythonRuntime.shared.startupDuration.map { Self.seconds($0) } ?? 0
            return String(format: "interpreter %.2f s", startup)
        }
        await step("configure") {
            try await self.ytDlp.setJavaScriptEnabled(javaScript)
            try await self.ytDlp.setDebugLogging(debug)
            return "JavaScriptCore \(javaScript ? "on" : "off")\(debug ? ", verbose log" : "")"
        }
        await step("version (waits for import yt_dlp)") {
            let version = try await self.ytDlp.version()
            return "yt-dlp \(version.ytDlp), Python \(version.python), \(version.openSSL)"
        }
        await step("first info") {
            let data = try await self.ytDlp.videoInfo(videoID: Self.infoVideo, cookies: nil)
            let info = try Self.object(data)
            let formats = (info["formats"] as? [[String: Any]]) ?? []
            let h264 = formats.filter { ($0["vcodec"] as? String)?.hasPrefix("avc1") == true }.compactMap { $0["height"] as? Int }
            let sinceLaunch = Self.seconds(ContinuousClock.now - launched)
            return "\(info["title"] ?? "?"), \(info["duration"] ?? "?") s, \(formats.count) formats, H.264 heights \(Set(h264).sorted()); \(String(format: "%.1f", sinceLaunch)) s since the self-test started"
        }
        await step("second info") {
            let data = try await self.ytDlp.videoInfo(videoID: Self.downloadVideo, cookies: nil)
            return "\(try Self.object(data)["title"] ?? "?")"
        }
        await step("info with cookies.txt") {
            let cookies = URL.temporaryDirectory.appending(path: "selftest-cookies.txt")
            let text = "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t2147483647\tPREF\thl=en&tz=UTC\n"
            try text.write(to: cookies, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: cookies) }
            let data = try await self.ytDlp.videoInfo(videoID: Self.downloadVideo, cookies: cookies)
            let unchanged = try String(contentsOf: cookies, encoding: .utf8) == text
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: URL.cachesDirectory.appending(path: "yt-dlp").path))?
                .filter { $0.hasPrefix("cookies-") } ?? []
            guard unchanged, leftovers.isEmpty else {
                throw YtDlpError.failed("cookies file changed: \(!unchanged), copies left: \(leftovers)")
            }
            return "\(try Self.object(data)["title"] ?? "?"); cookies.txt untouched, private copy removed"
        }
        await step("search") {
            let data = try await self.ytDlp.search("big buck bunny", count: 5)
            let entries = (try Self.object(data)["entries"] as? [[String: Any]]) ?? []
            guard !entries.isEmpty else { throw YtDlpError.failed("no results") }
            return "\(entries.count) results: \(entries.compactMap { $0["title"] as? String }.prefix(3).joined(separator: " | "))"
        }
        await step("channel videos tab") {
            let data = try await self.ytDlp.channelTab(channelID: Self.channel, tab: .videos, count: 5)
            let entries = (try Self.object(data)["entries"] as? [[String: Any]]) ?? []
            guard !entries.isEmpty else { throw YtDlpError.failed("no videos") }
            return "\(entries.count) videos, first: \(entries.first?["title"] ?? "?")"
        }
        await step("channel streams tab") {
            do {
                let data = try await self.ytDlp.channelTab(channelID: Self.channel, tab: .streams, count: 5)
                let entries = (try Self.object(data)["entries"] as? [[String: Any]]) ?? []
                return "\(entries.count) streams"
            } catch YtDlpError.failed(let message) {
                return "no Live tab (expected for some channels): \(message)"
            }
        }
        await step("comments") {
            let data = try await self.ytDlp.comments(videoID: Self.infoVideo, cookies: nil)
            let object = try Self.object(data)
            let comments = (object["comments"] as? [[String: Any]]) ?? []
            guard !comments.isEmpty else { throw YtDlpError.failed("no comments") }
            return "\(comments.count) comments of \(object["comment_count"] ?? "?")"
        }
        await step("cancel") {
            let task = Task { try await self.ytDlp.comments(videoID: Self.infoVideo, cookies: nil) }
            try await Task.sleep(for: .milliseconds(700))
            let clock = ContinuousClock()
            let cancelledAt = clock.now
            task.cancel()
            do {
                _ = try await task.value
                return "finished before the cancel arrived"
            } catch is CancellationError {
                return String(format: "stopped %.2f s after cancel", Self.seconds(clock.now - cancelledAt))
            }
        }
        await step("stream (HLS in AVPlayer)") {
            let stream = try await self.ytDlp.stream(videoID: Self.infoVideo, cookies: nil)
            guard let hls = stream.hlsURL else { throw YtDlpError.failed("no HLS manifest") }
            let asset = AVURLAsset(url: hls)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            guard playable, duration.seconds > 0 else {
                throw YtDlpError.failed("not playable (playable \(playable), duration \(duration.seconds))")
            }
            let item = AVPlayerItem(asset: asset)
            item.preferredMaximumResolution = YtDlpStream.preferredMaximumResolution
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.play()
            let ready = await Self.waitUntilReady(item, timeout: .seconds(20))
            let size = item.presentationSize
            player.pause()
            guard ready else { throw YtDlpError.failed("AVPlayerItem didn't become ready: \(item.error?.localizedDescription ?? "timeout")") }
            let expires = stream.expiresAt.map { "expires \($0.formatted(date: .omitted, time: .shortened))" } ?? "no expiry"
            return "playable, \(Int(duration.seconds)) s, item ready at \(Int(size.width))x\(Int(size.height)); fallback video \(stream.videoHeight ?? 0)p, progressive \(stream.progressiveHeight ?? 0)p; \(expires)"
        }
        var plan: YtDlpDownloadPlan?
        await step("download plan 480p") {
            let made = try await self.ytDlp.downloadPlan(videoID: Self.downloadVideo, maxHeight: 480, cookies: nil)
            plan = made
            return made.parts.map { "\($0.formatID) \($0.height.map { "\($0)p" } ?? "audio") \($0.videoCodec ?? $0.audioCodec ?? "") \($0.bytes ?? -1) B" }
                .joined(separator: " + ") + ", estimate \(made.estimatedBytes ?? -1) B"
        }
        if let plan {
            await step("download 480p and merge") {
                let file = URL.documentsDirectory.appending(path: "selftest/\(plan.videoID).mp4")
                try? FileManager.default.removeItem(at: file)
                let updates = OSAllocatedUnfairLock(initialState: [Int]())
                let saved = try await self.ytDlp.download(plan, to: file, cookies: nil) { progress in
                    updates.withLock { $0.append(progress.percent ?? -1) }
                }
                let tracks = try await MediaMerger.trackCounts(of: saved)
                guard tracks.video == 1, tracks.audio == 1, tracks.duration > 0 else {
                    throw YtDlpError.failed("tracks: \(tracks.video) video, \(tracks.audio) audio, \(tracks.duration) s")
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int) ?? 0
                let percents = updates.withLock { $0 }
                return "\(saved.lastPathComponent): \(size) B, \(tracks.video) video + \(tracks.audio) audio track, \(String(format: "%.1f", tracks.duration)) s; \(percents.count) progress updates, last \(percents.last ?? -1)%"
            }
        }
        await step("cancel a download") {
            let plan = try await self.ytDlp.downloadPlan(videoID: Self.infoVideo, maxHeight: 480, cookies: nil)
            let file = URL.documentsDirectory.appending(path: "selftest/cancelled.mp4")
            let started = OSAllocatedUnfairLock(initialState: false)
            let task = Task {
                try await self.ytDlp.download(plan, to: file, cookies: nil) { progress in
                    if progress.downloadedBytes > 0 { started.withLock { $0 = true } }
                }
            }
            let deadline = ContinuousClock.now + .seconds(15)
            while !started.withLock({ $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let whileDownloading = started.withLock { $0 }
            let clock = ContinuousClock()
            let cancelledAt = clock.now
            task.cancel()
            do {
                _ = try await task.value
                throw YtDlpError.failed("the download finished anyway")
            } catch is CancellationError {
                let parts = YtDlp.partsDirectory(for: file, videoID: plan.videoID)
                let leftover = FileManager.default.fileExists(atPath: parts.path)
                guard !leftover, !FileManager.default.fileExists(atPath: file.path) else {
                    throw YtDlpError.failed("files left behind")
                }
                return String(format: "stopped %.2f s after cancel (%@), \(plan.estimatedBytes ?? 0) B planned, nothing left behind",
                              Self.seconds(clock.now - cancelledAt), whileDownloading ? "while downloading" : "before the first byte")
            }
        }
        let javaScriptStats = JavaScriptRunner.statistics
        await step("JavaScriptCore challenge solving") {
            String(format: "%d runs, %.2f s in all", javaScriptStats.runs, javaScriptStats.seconds)
        }
        write()
    }

    private func step(_ name: String, _ body: @escaping @MainActor () async throws -> String) async {
        let clock = ContinuousClock()
        let began = clock.now
        let result: Step
        do {
            let detail = try await body()
            result = Step(name: name, passed: true, seconds: Self.seconds(clock.now - began), detail: detail)
        } catch {
            result = Step(name: name, passed: false, seconds: Self.seconds(clock.now - began), detail: "\(error.localizedDescription)")
        }
        steps.append(result)
        let line = "SELFTEST \(result.passed ? "PASS" : "FAIL") \(name) [\(String(format: "%.2f", result.seconds)) s] \(result.detail)"
        print(line)
        log.info("\(line, privacy: .public)")
    }

    private func write() {
        let summary = steps.allSatisfy(\.passed) ? "all passed" : "\(steps.filter { !$0.passed }.count) failed"
        print("SELFTEST DONE \(summary)")
        let file = URL.documentsDirectory.appending(path: "ytdlp-selftest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(steps).write(to: file)
    }

    private static func waitUntilReady(_ item: AVPlayerItem, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if item.status == .readyToPlay { return true }
            if item.status == .failed { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    nonisolated static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YtDlpError.failed("not a JSON object")
        }
        return object
    }
}
