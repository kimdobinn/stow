import Foundation

/// Errors StowKit throws. `message` is short enough to show as it is.
public enum StowError: Error, Equatable, Sendable, LocalizedError {
    /// The Mac unpaired this phone (or never paired it): Firestore refused the read or write.
    case notPaired
    case network(String)
    case parse(String)
    case server(String)
    /// The app was built without ios/Stow/Config/Firebase.plist.
    case notConfigured
    case pairing(String)

    public var message: String {
        switch self {
        case .notPaired: "This phone isn't paired with the Mac."
        case .network(let message), .parse(let message), .server(let message), .pairing(let message): message
        case .notConfigured: "This build has no Firebase settings. Run ios/scripts/firebase-config.sh and build again."
        }
    }

    public var errorDescription: String? { message }
}

/// A YouTube video, as the Mac describes it.
public struct Video: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var channelId: String
    public var channelTitle: String
    public var title: String
    public var publishedAt: Date?
    public var thumbnailURL: String?
    public var isMembersOnly: Bool
    public var liveStatus: String?
    /// Known up front only for videos from YouTube's own feeds and lists.
    public var durationSeconds: Int?

    public init(id: String, channelId: String, channelTitle: String, title: String, publishedAt: Date?,
                thumbnailURL: String?, isMembersOnly: Bool, liveStatus: String? = nil, durationSeconds: Int? = nil) {
        self.id = id
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.title = title
        self.publishedAt = publishedAt
        self.thumbnailURL = thumbnailURL
        self.isMembersOnly = isMembersOnly
        self.liveStatus = liveStatus
        self.durationSeconds = durationSeconds
    }

    public var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }

    /// A finished live stream ("Streamed").
    public var isPastStream: Bool { liveStatus == "wasLive" || liveStatus == "was_live" }

    /// YouTube Shorts are never shown: anything this short counts as one.
    public var isShort: Bool {
        guard let durationSeconds else { return false }
        return (1...Self.shortsMaxSeconds).contains(durationSeconds)
    }

    public static let shortsMaxSeconds = 60
}

/// A named set of channels (shared/phone): Home can show just their videos.
public struct ChannelGroup: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var channels: [GroupChannel]

    public init(id: String, name: String, channels: [GroupChannel]) {
        self.id = id
        self.name = name
        self.channels = channels
    }

    public var channelIds: Set<String> { Set(channels.map(\.id)) }
}

public struct GroupChannel: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A video sent to the phone (videos/{id}): by the Mac, or by a phone from a channel page.
public struct SentVideo: Hashable, Codable, Sendable {
    public var video: Video
    public var sentAt: Date?
    public var sentBy: String?
    public var watched: Bool

    public init(video: Video, sentAt: Date?, sentBy: String?, watched: Bool) {
        self.video = video
        self.sentAt = sentAt
        self.sentBy = sentBy
        self.watched = watched
    }
}

/// A channel the Mac follows (channels/{id}) with its newest videos.
public struct Channel: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var handle: String?
    public var avatarURL: String?
    public var order: Int
    /// Newest first.
    public var recent: [RecentVideo]

    public init(id: String, title: String, handle: String?, avatarURL: String?, order: Int, recent: [RecentVideo]) {
        self.id = id
        self.title = title
        self.handle = handle
        self.avatarURL = avatarURL
        self.order = order
        self.recent = recent
    }
}

public struct RecentVideo: Hashable, Codable, Sendable {
    public var video: Video
    public var watched: Bool

    public init(video: Video, watched: Bool) {
        self.video = video
        self.watched = watched
    }
}

public enum DownloadState: String, Codable, Sendable, CaseIterable {
    case queued, downloading, downloaded, failed, deleted
}

/// What this phone did with a video; kept on the phone only.
public struct LocalVideo: Hashable, Codable, Sendable {
    public var id: String
    public var state: DownloadState
    /// 0…100 while downloading.
    public var progress: Int
    public var error: String?
    /// The file's name in the downloads folder. Not a full path: iOS moves the app's container
    /// on updates, so absolute paths would go stale.
    public var fileName: String?
    public var sizeBytes: Int64
    public var durationMs: Int
    public var positionMs: Int
    /// The sentAt this state belongs to; a newer one ("Send to Phone Again") retries.
    public var sentAt: Date
    public var downloadedAt: Date?
    public var updatedAt: Date
    /// What the video is, so a download stays listed (and can be retried after a relaunch) when
    /// no feed, search or sent video mentions it any more.
    public var video: Video?
    /// Set while this phone's own request (picked from a search, channel page or YouTube's feeds)
    /// hasn't been seen on the server. Until then `sentAt` is the tap's time, not the server's
    /// stamp; the first server value seen replaces it, so it doesn't count as "sent again".
    public var requestedAt: Date?

    public init(id: String, state: DownloadState, progress: Int = 0, error: String? = nil, fileName: String? = nil,
                sizeBytes: Int64 = 0, durationMs: Int = 0, positionMs: Int = 0,
                sentAt: Date = Date(timeIntervalSince1970: 0), downloadedAt: Date? = nil, updatedAt: Date = .now,
                video: Video? = nil, requestedAt: Date? = nil) {
        self.id = id
        self.state = state
        self.progress = progress
        self.error = error
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.durationMs = durationMs
        self.positionMs = positionMs
        self.sentAt = sentAt
        self.downloadedAt = downloadedAt
        self.updatedAt = updatedAt
        self.video = video
        self.requestedAt = requestedAt
    }
}

/// A video as the app shows it: what it is, whether it was sent, and what the phone has.
public struct VideoItem: Hashable, Sendable, Identifiable {
    public var video: Video
    public var sent: SentVideo?
    public var local: LocalVideo?
    public var watchedOnMac: Bool
    /// Only in YouTube's Home or Subscriptions feed (or a search): not from a Stow channel, never sent.
    public var onlyInYouTubeFeeds: Bool
    /// Only known from a YouTube search or channel page on the phone (kept out of Home and the other lists).
    public var fromSearch: Bool

    public init(video: Video, sent: SentVideo?, local: LocalVideo?, watchedOnMac: Bool,
                onlyInYouTubeFeeds: Bool = false, fromSearch: Bool = false) {
        self.video = video
        self.sent = sent
        self.local = local
        self.watchedOnMac = watchedOnMac
        self.onlyInYouTubeFeeds = onlyInYouTubeFeeds
        self.fromSearch = fromSearch
    }

    public var id: String { video.id }
    public var watched: Bool { sent?.watched ?? watchedOnMac }
    /// nil when it was never downloaded (or the download was deleted).
    public var state: DownloadState? { local?.state == .deleted ? nil : local?.state }
    public var isPlayable: Bool { local?.state == .downloaded && local?.fileName != nil }
    public var isDownloading: Bool { state == .queued || state == .downloading }
    public var durationMs: Int {
        if let local, local.durationMs > 0 { return local.durationMs }
        return (video.durationSeconds ?? 0) * 1000
    }

    /// How far you got, 0…1 (1 once watched).
    public var progress: Double {
        if watched { return 1 }
        if let local, local.durationMs > 0 { return min(max(Double(local.positionMs) / Double(local.durationMs), 0), 1) }
        return 0
    }

    /// For newest-first lists: the upload date, else when it was sent.
    public var sortDate: Date? { video.publishedAt ?? sent?.sentAt }
}

/// A list of videos you made on the phone.
public struct Playlist: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var videoIds: [String]
    public var createdAt: Date

    public init(id: String, name: String, videoIds: [String], createdAt: Date) {
        self.id = id
        self.name = name
        self.videoIds = videoIds
        self.createdAt = createdAt
    }
}

public enum DownloadSort: String, Codable, Sendable, CaseIterable {
    case recentlyDownloaded, newest, oldest, channel, longest, shortest, title

    public var label: String {
        switch self {
        case .recentlyDownloaded: "Recently downloaded"
        case .newest: "Upload date (newest)"
        case .oldest: "Upload date (oldest)"
        case .channel: "Channel (A–Z)"
        case .longest: "Length (longest)"
        case .shortest: "Length (shortest)"
        case .title: "Title (A–Z)"
        }
    }
}

public enum WatchFilter: String, Codable, Sendable, CaseIterable {
    case all, unwatched, watched

    public var label: String {
        switch self {
        case .all: "All"
        case .unwatched: "Unwatched"
        case .watched: "Watched"
        }
    }
}

/// The app's look. Paper is a light theme in warm off-white with a terracotta accent.
public enum AppTheme: String, Codable, Sendable, CaseIterable {
    case system, light, dark, paper

    public var label: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        case .paper: "Paper"
        }
    }

    public func isDark(systemDark: Bool) -> Bool {
        switch self {
        case .system: systemDark
        case .dark: true
        case .light, .paper: false
        }
    }
}

/// The highest resolution downloads take.
public enum DownloadQuality: String, Codable, Sendable, CaseIterable {
    case best, p1440, p1080, p720, p480

    public var height: Int? {
        switch self {
        case .best: nil
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }

    public var label: String {
        switch self {
        case .best: "Best available"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    public var detail: String {
        switch self {
        case .best: "Up to 4K or more; the largest files"
        case .p1440: "Sharper than 1080p on a big screen; about twice the size"
        case .p1080: "Full HD"
        case .p720: "About half the size of 1080p"
        case .p480: "Smallest; fine for talks and podcasts"
        }
    }

    /// yt-dlp's `-S`, as on Android: the highest resolution up to the cap, then the highest frame
    /// rate, then H.264 and AAC.
    public var formatSort: String { "\(height.map { "res:\($0)" } ?? "res"),fps,vcodec:h264,acodec:m4a" }

    /// The tallest video the iPhone can download: with no ffmpeg, AVFoundation merges the parts
    /// without re-encoding, and YouTube has no H.264 above 1080p.
    public static let maxSupportedHeight = 1080

    /// The qualities this build offers, best first.
    public static var available: [DownloadQuality] {
        allCases.filter { quality in quality.height.map { $0 <= maxSupportedHeight } ?? false }
    }

    /// This quality, or the best available one when this build can't download it.
    public var supported: DownloadQuality {
        Self.available.contains(self) ? self : Self.available.first ?? .p1080
    }
}

/// What YouTube itself would show the account, as the Mac last read it (its Home
/// recommendations and the Subscriptions feed), in YouTube's order.
public struct YouTubeFeeds: Hashable, Sendable {
    public var recommended: [Video]
    public var subscriptions: [Video]
    /// Pictures of the channels in them, by channel id (the Mac looks them up; the feeds have none).
    public var channelAvatars: [String: String]

    public init(recommended: [Video] = [], subscriptions: [Video] = [], channelAvatars: [String: String] = [:]) {
        self.recommended = recommended
        self.subscriptions = subscriptions
        self.channelAvatars = channelAvatars
    }

    public var isEmpty: Bool { recommended.isEmpty && subscriptions.isEmpty }

    /// The Mac's AccountFeeds JSON. Leaves out Shorts and streams that are live now.
    public static func parse(_ json: String) throws -> YouTubeFeeds {
        try parse(Data(json.utf8))
    }

    public static func parse(_ data: Data) throws -> YouTubeFeeds {
        let root = try JSONObject(parsing: data)
        func list(_ key: String) -> [Video] {
            (root.objects(key) ?? []).compactMap { o -> Video? in
                guard let id = o.string("id") else { return nil }
                let live: String? = o.bool("wasLive") ? "wasLive" : o.bool("isLive") ? "is_live" : nil
                let video = Video(
                    id: id,
                    channelId: o.string("channelId") ?? "",
                    channelTitle: o.string("channelTitle") ?? "",
                    title: o.string("title") ?? id,
                    publishedAt: o.number("timestamp").map(Date.init(epochSeconds:)),
                    thumbnailURL: o.string("thumbnailURL"),
                    isMembersOnly: o.bool("isMembersOnly"),
                    liveStatus: live,
                    durationSeconds: o.int("duration")
                )
                return video.isShort || video.liveStatus == "is_live" ? nil : video
            }
        }
        var avatars: [String: String] = [:]
        if let object = root.object("channelAvatars") {
            for key in object.raw.keys {
                if let url = object.string(key) { avatars[key] = url }
            }
        }
        return YouTubeFeeds(recommended: list("recommended"), subscriptions: list("subscriptions"), channelAvatars: avatars)
    }
}

/// A channel's latest uploads and past streams, loaded on the phone for channels the Mac doesn't follow.
public struct ChannelPage: Hashable, Sendable {
    public var title: String
    public var avatarURL: String?
    public var videoIds: [String]
    public var streamIds: [String]
    public var loadedAt: Date

    public init(title: String, avatarURL: String?, videoIds: [String], streamIds: [String], loadedAt: Date) {
        self.title = title
        self.avatarURL = avatarURL
        self.videoIds = videoIds
        self.streamIds = streamIds
        self.loadedAt = loadedAt
    }
}

/// A channel as Subscriptions and the group editor list it.
public struct KnownChannel: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var avatarURL: String?

    public init(id: String, title: String, avatarURL: String?) {
        self.id = id
        self.title = title
        self.avatarURL = avatarURL
    }
}

/// The answer to pull-to-refresh.
public enum RefreshResult: Sendable {
    case done
    /// The Mac didn't answer in time (Stow isn't running on it, or it's asleep).
    case noAnswer
    case failed
}

public enum PairState: Equatable, Sendable {
    case unpaired(message: String?)
    case pairing
    case paired
}
