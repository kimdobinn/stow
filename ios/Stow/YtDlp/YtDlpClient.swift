import Foundation
import os

/// yt-dlp on the embedded Python (see `YtDlpService` for what each call does).
nonisolated final class YtDlp: YtDlpService {
    static let shared = YtDlp(runtime: .shared)

    private let runtime: PythonRuntime
    private let log = Logger(subsystem: "dev.stow.ios", category: "yt-dlp")
    private let lastSearch = OSAllocatedUnfairLock<Task<Data, any Error>?>(initialState: nil)

    init(runtime: PythonRuntime) {
        self.runtime = runtime
    }

    func prepare() async throws {
        try await runtime.start()
    }

    func version() async throws -> YtDlpVersion {
        try JSONDecoder().decode(YtDlpVersion.self, from: await runtime.call(["op": "version"]))
    }

    /// Turns solving YouTube's JavaScript challenges (JavaScriptCore) on or off. Without it yt-dlp
    /// asks YouTube only as a client that needs none, which may offer fewer formats.
    func setJavaScriptEnabled(_ enabled: Bool) async throws {
        _ = try await runtime.call(["op": "configure", "javascript": enabled])
    }

    /// Sends all of yt-dlp's messages (verbose) to the system log.
    func setDebugLogging(_ enabled: Bool) async throws {
        _ = try await runtime.call(["op": "configure", "debug": enabled])
    }

    func videoInfo(videoID: String, cookies: URL?) async throws -> Data {
        try await runtime.call(request("info", videoID: videoID, cookies: cookies))
    }

    func search(_ query: String, count: Int) async throws -> Data {
        let runtime = runtime
        let task = Task { try await runtime.call(["op": "search", "query": query, "count": count]) }
        // One search at a time, as on Android: typing on stops the search before.
        let previous = lastSearch.withLock { last in
            defer { last = task }
            return last
        }
        previous?.cancel()
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func channelTab(channelID: String, tab: YtDlpChannelTab, count: Int) async throws -> Data {
        try await runtime.call(["op": "channel", "channel_id": channelID, "tab": tab.rawValue, "count": count])
    }

    func comments(videoID: String, cookies: URL?) async throws -> Data {
        try await runtime.call(request("comments", videoID: videoID, cookies: cookies))
    }

    func stream(videoID: String, cookies: URL?) async throws -> YtDlpStream {
        let data = try await runtime.call(request("stream", videoID: videoID, cookies: cookies))
        let stream = try Self.parseStream(data, videoID: videoID)
        if stream.hlsURL == nil && stream.videoURL == nil && stream.progressiveURL == nil {
            throw YtDlpError.noPlayableFormat
        }
        return stream
    }

    func downloadPlan(videoID: String, maxHeight: Int, cookies: URL?) async throws -> YtDlpDownloadPlan {
        var body = request("plan", videoID: videoID, cookies: cookies)
        body["max_height"] = maxHeight
        let data = try await runtime.call(body)
        return try JSONDecoder().decode(YtDlpDownloadPlan.self, from: data)
    }

    func download(_ plan: YtDlpDownloadPlan, to file: URL, cookies: URL?,
                  progress: @escaping @Sendable (YtDlpProgress) -> Void) async throws -> URL {
        let parts = Self.partsDirectory(for: file, videoID: plan.videoID)
        var body = request("download", videoID: plan.videoID, cookies: cookies)
        body["format_ids"] = plan.parts.map(\.formatID)
        body["dir"] = parts.path
        let clock = ContinuousClock()
        let began = clock.now
        let data: Data
        do {
            data = try await runtime.call(body) { payload in
                if let update = Self.parseProgress(payload) { progress(update) }
            }
        } catch is CancellationError {
            if !Self.keepsPartsOnCancel { try? FileManager.default.removeItem(at: parts) }
            throw CancellationError()
        }
        let result = try JSONDecoder().decode(DownloadResult.self, from: data)
        let total = result.files.reduce(Int64(0)) { $0 + (Self.fileSize($1.path) ?? 0) }
        progress(YtDlpProgress(phase: .merging, downloadedBytes: total, totalBytes: total))

        let video = result.files.first(where: \.hasVideo)
        let audio = result.files.first(where: { !$0.hasVideo && $0.hasAudio })
        guard let video else { throw YtDlpError.noPlayableFormat }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let merged = parts.appending(path: "merged.mp4")
        let downloaded = clock.now
        do {
            try await MediaMerger.merge(video: URL(filePath: video.path),
                                        audio: audio.map { URL(filePath: $0.path) }, to: merged)
        } catch is CancellationError {
            if !Self.keepsPartsOnCancel { try? FileManager.default.removeItem(at: parts) }
            throw CancellationError()
        }
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: merged)
        } else {
            try FileManager.default.moveItem(at: merged, to: file)
        }
        try? FileManager.default.removeItem(at: parts)
        log.info("Downloaded \(plan.videoID, privacy: .public) (\(total) B) in \(downloaded - began, privacy: .public), merged in \(clock.now - downloaded, privacy: .public)")
        return file
    }

    // MARK: - Helpers

    private func request(_ op: String, videoID: String, cookies: URL?) -> [String: Any] {
        var body: [String: Any] = ["op": op, "id": videoID]
        if let cookies { body["cookies"] = cookies.path }
        return body
    }

    /// Set for a download to keep its partial files when it's cancelled (a pause rather than a
    /// stop); whoever cancels for good deletes `partsDirectory(for:videoID:)` itself.
    @TaskLocal static var keepsPartsOnCancel = false

    /// Partial downloads live in a hidden folder next to the file, so a retry resumes them.
    static func partsDirectory(for file: URL, videoID: String) -> URL {
        file.deletingLastPathComponent().appending(path: ".parts", directoryHint: .isDirectory)
            .appending(path: videoID, directoryHint: .isDirectory)
    }

    private static func fileSize(_ path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    private struct DownloadResult: Decodable {
        struct File: Decodable {
            var path: String
            var hasVideo: Bool
            var hasAudio: Bool
            enum CodingKeys: String, CodingKey { case path, hasVideo = "has_video", hasAudio = "has_audio" }
        }
        var files: [File]
    }

    static func parseProgress(_ data: Data) -> YtDlpProgress? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func int64(_ key: String) -> Int64? { (object[key] as? NSNumber)?.int64Value }
        return YtDlpProgress(
            phase: .downloading,
            downloadedBytes: int64("downloaded") ?? 0,
            totalBytes: int64("total"),
            bytesPerSecond: (object["speed"] as? NSNumber)?.doubleValue,
            secondsLeft: (object["eta"] as? NSNumber)?.doubleValue)
    }

    static func parseStream(_ data: Data, videoID: String) throws -> YtDlpStream {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YtDlpError.failed("unexpected answer from yt-dlp")
        }
        func url(_ key: String) -> URL? { (object[key] as? String).flatMap(URL.init(string:)) }
        let hls = url("hls")
        let video = url("video")
        let progressive = url("progressive")
        return YtDlpStream(
            videoID: object["id"] as? String ?? videoID,
            hlsURL: hls,
            videoURL: video,
            videoHeight: object["video_height"] as? Int,
            audioURL: url("audio"),
            progressiveURL: progressive,
            progressiveHeight: object["progressive_height"] as? Int,
            headers: object["headers"] as? [String: String] ?? [:],
            duration: (object["duration"] as? NSNumber)?.doubleValue,
            isLive: object["is_live"] as? Bool ?? false,
            expiresAt: [hls, video, progressive].compactMap { $0.flatMap(expiry(of:)) }.min())
    }

    /// googlevideo URLs carry their expiry as `expire=<unix time>`, HLS manifests as `/expire/<unix time>/`.
    static func expiry(of url: URL) -> Date? {
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "expire" })?.value, let seconds = TimeInterval(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        let components = url.pathComponents
        if let index = components.firstIndex(of: "expire"), index + 1 < components.count,
           let seconds = TimeInterval(components[index + 1]) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
