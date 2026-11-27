import Foundation

/// Answers at once with fixed data: for SwiftUI previews, demo mode and UI tests.
/// Set the properties to change what it answers; `failure` makes every call throw.
nonisolated struct FakeYtDlp: YtDlpService {
    var searchJSON = Data(#"{"_type":"playlist","id":"search","title":"search","entries":[{"_type":"url","ie_key":"Youtube","id":"aqz-KE-bpKQ","url":"https://www.youtube.com/watch?v=aqz-KE-bpKQ","title":"Big Buck Bunny 60fps 4K","channel":"Blender","channel_id":"UCSMOQeBJ2RAnuFungnQOxLg","duration":635,"view_count":1000000}]}"#.utf8)
    var infoJSON = Data(#"{"id":"aqz-KE-bpKQ","title":"Big Buck Bunny 60fps 4K","channel":"Blender","channel_id":"UCSMOQeBJ2RAnuFungnQOxLg","duration":635,"description":"A short film by the Blender Institute."}"#.utf8)
    var commentsJSON = Data(#"{"comments":[{"id":"c1","parent":"root","text":"Still a classic.","author":"@viewer","like_count":12,"timestamp":1700000000}],"comment_count":1}"#.utf8)
    var streamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!
    var plannedBytes: Int64? = 48_000_000
    var failure: YtDlpError?

    init() {}

    func prepare() async throws { try check() }

    func version() async throws -> YtDlpVersion {
        try check()
        return YtDlpVersion(ytDlp: "fake", python: "3.14", openSSL: "none", javaScript: false)
    }

    func videoInfo(videoID: String, cookies: URL?) async throws -> Data { try check(); return infoJSON }

    func search(_ query: String, count: Int) async throws -> Data { try check(); return searchJSON }

    func channelTab(channelID: String, tab: YtDlpChannelTab, count: Int) async throws -> Data {
        try check()
        return searchJSON
    }

    func comments(videoID: String, cookies: URL?) async throws -> Data { try check(); return commentsJSON }

    func stream(videoID: String, cookies: URL?) async throws -> YtDlpStream {
        try check()
        return YtDlpStream(videoID: videoID, hlsURL: streamURL, headers: [:], duration: 600, isLive: false)
    }

    func downloadPlan(videoID: String, maxHeight: Int, cookies: URL?) async throws -> YtDlpDownloadPlan {
        try check()
        let height = min(maxHeight, 1080)
        return YtDlpDownloadPlan(
            videoID: videoID, title: "Big Buck Bunny 60fps 4K", duration: 635, maxHeight: height,
            parts: [
                .init(formatID: "137", ext: "mp4", hasVideo: true, hasAudio: false, height: height, width: height * 16 / 9,
                      fps: 30, videoCodec: "avc1.640028", audioCodec: nil, bytes: plannedBytes.map { $0 - 8_000_000 }),
                .init(formatID: "140", ext: "m4a", hasVideo: false, hasAudio: true, height: nil, width: nil,
                      fps: nil, videoCodec: nil, audioCodec: "mp4a.40.2", bytes: plannedBytes.map { _ in 8_000_000 }),
            ],
            estimatedBytes: plannedBytes)
    }

    /// Reports progress over about a second; writes no real video.
    func download(_ plan: YtDlpDownloadPlan, to file: URL, cookies: URL?,
                  progress: @escaping @Sendable (YtDlpProgress) -> Void) async throws -> URL {
        try check()
        let total = plan.estimatedBytes ?? 1
        for step in 1...10 {
            try await Task.sleep(for: .milliseconds(100))
            progress(YtDlpProgress(phase: .downloading, downloadedBytes: total * Int64(step) / 10, totalBytes: total))
        }
        progress(YtDlpProgress(phase: .merging, downloadedBytes: total, totalBytes: total))
        return file
    }

    private func check() throws {
        if let failure { throw failure }
    }
}
