import Foundation
import StowKit

/// StowKit's way to YouTube, through the app's embedded yt-dlp.
nonisolated struct YtDlpTool: YouTubeTool {
    let ytdlp: any YtDlpService

    init(ytdlp: any YtDlpService = YtDlp.shared) {
        self.ytdlp = ytdlp
    }

    func info(videoId: String, cookies: URL?) async throws -> String {
        try await text(ytdlp.videoInfo(videoID: videoId, cookies: cookies))
    }

    func search(_ query: String, count: Int) async throws -> String {
        try await text(ytdlp.search(query, count: count))
    }

    func channelTab(channelId: String, tab: ChannelTab, count: Int) async throws -> String {
        let tab: YtDlpChannelTab = tab == .streams ? .streams : .videos
        return try await text(ytdlp.channelTab(channelID: channelId, tab: tab, count: count))
    }

    func comments(videoId: String, cookies: URL?) async throws -> String {
        try await text(ytdlp.comments(videoID: videoId, cookies: cookies))
    }

    func flatListing(_ url: String, count: Int, cookies: URL?) async throws -> FlatListing {
        let listing = try await ytdlp.flatListing(url: url, count: count, cookies: cookies)
        return FlatListing(json: text(listing.json), cookiesRejected: listing.cookiesRejected)
    }

    func markWatched(videoId: String, cookies: URL) async throws {
        try await ytdlp.markWatched(videoID: videoId, cookies: cookies)
    }

    /// HLS first (AVPlayer picks the quality, capped by the player); then separate H.264 and AAC;
    /// then the single progressive file.
    func stream(_ video: Video, cookies: URL?) async throws -> StreamInfo {
        let stream = try await ytdlp.stream(videoID: video.id, cookies: cookies)
        if let hls = stream.hlsURL {
            return StreamInfo(url: hls, headers: stream.headers, expiresAt: stream.expiresAt)
        }
        if let videoURL = stream.videoURL, let audioURL = stream.audioURL {
            return StreamInfo(url: videoURL, headers: stream.headers, audioURL: audioURL, expiresAt: stream.expiresAt)
        }
        if let progressive = stream.progressiveURL {
            return StreamInfo(url: progressive, headers: stream.headers, expiresAt: stream.expiresAt)
        }
        throw YtDlpError.noPlayableFormat
    }

    func downloadSize(_ video: Video, cookies: URL?, quality: DownloadQuality) async throws -> Int64? {
        try await ytdlp.downloadPlan(videoID: video.id, maxHeight: Self.maxHeight(quality), cookies: cookies).estimatedBytes
    }

    func download(_ video: Video, cookies: URL?, quality: DownloadQuality, to directory: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(video.id).mp4")
        // The download queue stops a download to pause it too (Wi-Fi lost, the app suspended):
        // what's down stays, and the queue deletes it when the download is dropped for good.
        return try await YtDlp.$keepsPartsOnCancel.withValue(true) {
            try await ytdlp.download(videoID: video.id, maxHeight: Self.maxHeight(quality), to: file, cookies: cookies) { update in
                if let fraction = update.fraction { progress(fraction) }
            }
        }
    }

    /// The download manager cancels the task running `download`, which stops yt-dlp; nothing
    /// else is running per video.
    func cancel(videoId: String) {}

    static func maxHeight(_ quality: DownloadQuality) -> Int {
        min(quality.height ?? DownloadQuality.maxSupportedHeight, DownloadQuality.maxSupportedHeight)
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
