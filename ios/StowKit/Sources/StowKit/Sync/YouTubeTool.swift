import Foundation

/// How StowKit reaches YouTube: the app plugs in its yt-dlp wrapper, tests a fake.
///
/// The listing calls return yt-dlp's JSON as it printed it (StowKit parses it with
/// `YouTubeListing` and `Comments`, so the parsing is tested here). `cookies` is a Netscape
/// cookies.txt for members-only videos, or nil; the caller deletes it afterwards. Calls throw
/// `CancellationError` when stopped, and a short message (yt-dlp's ERROR lines) otherwise.
public protocol YouTubeTool: Sendable {
    /// yt-dlp's `-j` answer for one video (title, formats, duration, …).
    func info(videoId: String, cookies: URL?) async throws -> String

    /// `ytsearch<count>:<query> --flat-playlist -J`. A new search stops the previous one.
    func search(_ query: String, count: Int) async throws -> String

    /// `https://www.youtube.com/channel/<id>/<tab> --flat-playlist -J --playlist-end <count>`.
    /// A channel without live streams has no "streams" tab: that throws.
    func channelTab(channelId: String, tab: ChannelTab, count: Int) async throws -> String

    /// `-j --skip-download --write-comments` with `Comments.limits` and comment_sort=top, trimmed
    /// with `Comments.trim` or not (StowKit trims again before saving).
    func comments(videoId: String, cookies: URL?) async throws -> String

    /// Where AVPlayer can stream the video from (YouTube's HLS manifest, H.264 up to 1080p).
    func stream(_ video: Video, cookies: URL?) async throws -> StreamInfo

    /// What a download in `quality` would take, in bytes; nil when yt-dlp doesn't say.
    func downloadSize(_ video: Video, cookies: URL?, quality: DownloadQuality) async throws -> Int64?

    /// Downloads the video (H.264 video and AAC audio, merged to .mp4) into `directory`, named
    /// `<id>.mp4`, and returns the file. `progress` gets 0…1, from any thread.
    ///
    /// What's downloaded so far stays in `<directory>/.parts/<id>/` when the download fails or is
    /// canceled, so the next try resumes it; the download queue deletes it when a download is
    /// dropped for good (`LocalStore.partsDirectory(for:)`).
    func download(_ video: Video, cookies: URL?, quality: DownloadQuality, to directory: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL

    /// Stops the download of this video id, if one is running (the task is canceled too).
    func cancel(videoId: String)
}

public enum ChannelTab: String, Sendable {
    case videos, streams
}

/// A playable stream for AVPlayer.
public struct StreamInfo: Hashable, Sendable {
    public var url: URL
    /// HTTP headers AVPlayer must send (AVURLAssetHTTPHeaderFieldsKey).
    public var headers: [String: String]
    /// Separate audio, when the video URL has none (AVPlayer then needs a composition).
    public var audioURL: URL?
    /// How long YouTube keeps the URL working.
    public var expiresAt: Date?

    public init(url: URL, headers: [String: String] = [:], audioURL: URL? = nil, expiresAt: Date? = nil) {
        self.url = url
        self.headers = headers
        self.audioURL = audioURL
        self.expiresAt = expiresAt
    }
}
