import CoreGraphics
import Foundation

/// What the app needs from yt-dlp (the iPhone's counterpart of Android's sync/YtDlp.kt).
///
/// Every method can be called from the main actor; the work runs on Python's threads. Cancelling
/// the calling task stops the call at yt-dlp's next HTTP request or progress update and throws
/// `CancellationError`. Failures throw `YtDlpError`. `cookies` is a Netscape cookies.txt (members-only
/// videos); yt-dlp gets a private copy, so the file is never changed.
///
/// `YtDlp.shared` is the real one; `FakeYtDlp` answers instantly for previews and UI tests.
nonisolated protocol YtDlpService: Sendable {
    /// Starts the interpreter and loads yt-dlp in the background (call at launch; optional).
    func prepare() async throws

    /// yt-dlp's and Python's versions.
    func version() async throws -> YtDlpVersion

    /// The video's full info as yt-dlp's JSON (`yt-dlp -j`; a few seconds).
    func videoInfo(videoID: String, cookies: URL?) async throws -> Data

    /// YouTube's search results as yt-dlp's flat-playlist JSON (`ytsearchN:`; not personalized).
    /// A new search cancels the one before it.
    func search(_ query: String, count: Int) async throws -> Data

    /// A channel's latest `count` videos or past live streams, as yt-dlp's flat-playlist JSON.
    /// A channel without live streams has no Streams tab: that throws `YtDlpError.failed`.
    func channelTab(channelID: String, tab: YtDlpChannelTab, count: Int) async throws -> Data

    /// The video's top comments: `{"comments": [...], "comment_count": n}` (about 5-10 s), as Android.
    func comments(videoID: String, cookies: URL?) async throws -> Data

    /// Where AVPlayer can stream the video from (a few seconds).
    func stream(videoID: String, cookies: URL?) async throws -> YtDlpStream

    /// The formats a download of at most `maxHeight` (capped at 1080) would take, and their size.
    func downloadPlan(videoID: String, maxHeight: Int, cookies: URL?) async throws -> YtDlpDownloadPlan

    /// Downloads the plan's formats and merges them into one .mp4 at `file` (replacing it).
    /// Partial downloads are kept next to `file` and resumed on the next try, unless cancelled.
    func download(_ plan: YtDlpDownloadPlan, to file: URL, cookies: URL?,
                  progress: @escaping @Sendable (YtDlpProgress) -> Void) async throws -> URL
}

nonisolated extension YtDlpService {
    /// Plans and downloads in one go (the plan's size is then not shown first).
    func download(videoID: String, maxHeight: Int, to file: URL, cookies: URL?,
                  progress: @escaping @Sendable (YtDlpProgress) -> Void) async throws -> URL {
        let plan = try await downloadPlan(videoID: videoID, maxHeight: maxHeight, cookies: cookies)
        return try await download(plan, to: file, cookies: cookies, progress: progress)
    }
}

nonisolated enum YtDlpChannelTab: String, Sendable, CaseIterable {
    case videos
    case streams
}

nonisolated struct YtDlpVersion: Sendable, Equatable, Codable {
    var ytDlp: String
    var python: String
    var openSSL: String
    /// Whether YouTube's JavaScript challenges are solved (with JavaScriptCore).
    var javaScript: Bool

    enum CodingKeys: String, CodingKey {
        case ytDlp = "yt_dlp", python, openSSL = "openssl", javaScript = "javascript"
    }
}

nonisolated struct YtDlpStream: Sendable, Equatable {
    var videoID: String
    /// YouTube's HLS master manifest: AVPlayer picks the quality. Cap it at 1080p with
    /// `AVPlayerItem.preferredMaximumResolution` (see `YtDlpStream.preferredMaximumResolution`).
    var hlsURL: URL?
    /// H.264 video only (up to 1080p) and AAC audio only: for an AVMutableComposition when there's no HLS.
    var videoURL: URL?
    var videoHeight: Int?
    var audioURL: URL?
    /// One file with both (usually 360p), the last resort.
    var progressiveURL: URL?
    var progressiveHeight: Int?
    /// HTTP headers YouTube expects for the non-HLS URLs (`AVURLAssetHTTPHeaderFieldsKey`).
    var headers: [String: String]
    var duration: TimeInterval?
    var isLive: Bool
    /// When YouTube stops accepting these URLs (about 6 hours after they were made).
    var expiresAt: Date?

    /// Streams are capped like downloads: YouTube's HLS also lists 1440p and 4K (VP9).
    static let preferredMaximumResolution = CGSize(width: 1920, height: 1080)
}

nonisolated struct YtDlpDownloadPlan: Sendable, Equatable, Codable {
    nonisolated struct Part: Sendable, Equatable, Codable {
        var formatID: String
        var ext: String?
        var hasVideo: Bool
        var hasAudio: Bool
        var height: Int?
        var width: Int?
        var fps: Double?
        var videoCodec: String?
        var audioCodec: String?
        /// yt-dlp's figure (exact or approximate); nil when YouTube doesn't say.
        var bytes: Int64?

        enum CodingKeys: String, CodingKey {
            case formatID = "format_id", ext, hasVideo = "has_video", hasAudio = "has_audio", height, width, fps
            case videoCodec = "vcodec", audioCodec = "acodec", bytes
        }
    }

    var videoID: String
    var title: String?
    var duration: TimeInterval?
    /// The cap it was made for (at most 1080).
    var maxHeight: Int
    /// One video part and one audio part, or one part with both.
    var parts: [Part]
    /// What the download will take, in bytes; nil when YouTube doesn't say for every part.
    var estimatedBytes: Int64?

    var height: Int? { parts.first(where: \.hasVideo)?.height }

    enum CodingKeys: String, CodingKey {
        case videoID = "id", title, duration, maxHeight = "max_height", parts, estimatedBytes = "estimated_bytes"
    }
}

nonisolated struct YtDlpProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case downloading
        /// Putting video and audio into one file (a few seconds at most).
        case merging
    }

    var phase: Phase
    var downloadedBytes: Int64
    var totalBytes: Int64?
    var bytesPerSecond: Double?
    var secondsLeft: Double?

    /// 0...1, or nil when the size isn't known yet.
    var fraction: Double? {
        if phase == .merging { return 1 }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    /// Whole percent, as Android reports it.
    var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }
}

nonisolated enum YtDlpError: LocalizedError, Equatable {
    /// The interpreter or yt-dlp couldn't start (a broken build).
    case unavailable(String)
    /// yt-dlp's error (its ERROR lines, shortened), e.g. "Video unavailable".
    case failed(String)
    /// YouTube offers nothing AVPlayer or AVFoundation can use for this video.
    case noPlayableFormat
    /// AVFoundation couldn't put video and audio together.
    case mergeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): "yt-dlp isn't available: \(message)"
        case .failed(let message): message
        case .noPlayableFormat: "This video can't be played on iPhone"
        case .mergeFailed(let message): "Couldn't save the video: \(message)"
        }
    }
}
