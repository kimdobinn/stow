import Foundation

/// A video as standalone.json keeps it (the same field names on Android).
public struct StoredVideo: Codable, Hashable, Sendable {
    public var id: String
    public var channelId: String
    public var channelTitle: String
    public var title: String
    public var publishedAt: Date?
    public var thumbnailURL: String?
    public var isMembersOnly: Bool
    /// "none", "wasLive" or "unknown".
    public var liveStatus: String
    /// Seconds.
    public var duration: Int?
    /// When Stow first saw it; undated videos take it as their date.
    public var foundAt: Date?

    public init(_ video: Video, foundAt: Date? = nil) {
        id = video.id
        channelId = video.channelId
        channelTitle = video.channelTitle
        title = video.title
        publishedAt = video.publishedAt
        thumbnailURL = video.thumbnailURL
        isMembersOnly = video.isMembersOnly
        liveStatus = video.isPastStream ? "wasLive" : video.liveStatus == "unknown" ? "unknown" : "none"
        duration = video.durationSeconds
        self.foundAt = foundAt
    }

    public var video: Video {
        Video(id: id, channelId: channelId, channelTitle: channelTitle, title: title, publishedAt: publishedAt,
              thumbnailURL: thumbnailURL, isMembersOnly: isMembersOnly,
              liveStatus: liveStatus == "none" ? nil : liveStatus, durationSeconds: duration)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        channelId = (try? c.decodeIfPresent(String.self, forKey: .channelId)) ?? ""
        channelTitle = (try? c.decodeIfPresent(String.self, forKey: .channelTitle)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? id
        publishedAt = try? c.decodeIfPresent(Date.self, forKey: .publishedAt)
        thumbnailURL = try? c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        isMembersOnly = (try? c.decodeIfPresent(Bool.self, forKey: .isMembersOnly)) ?? false
        liveStatus = (try? c.decodeIfPresent(String.self, forKey: .liveStatus)) ?? "none"
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)).map { Int($0) }
        foundAt = try? c.decodeIfPresent(Date.self, forKey: .foundAt)
    }
}

/// A channel this phone follows.
public struct FollowedChannel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var handle: String?
    public var avatarURL: String?
    public var addedAt: Date?

    public init(id: String, title: String, handle: String? = nil, avatarURL: String? = nil, addedAt: Date? = .now) {
        self.id = id
        self.title = title
        self.handle = handle
        self.avatarURL = avatarURL
        self.addedAt = addedAt
    }

    public init(_ info: ChannelInfo, addedAt: Date = .now) {
        self.init(id: info.id, title: info.title, handle: info.handle, avatarURL: info.avatarURL, addedAt: addedAt)
    }
}

/// When each of a channel's feeds was last read.
public struct FeedTimes: Codable, Hashable, Sendable {
    public var uploads: Date?
    public var streams: Date?
    public var members: Date?

    public init(uploads: Date? = nil, streams: Date? = nil, members: Date? = nil) {
        self.uploads = uploads
        self.streams = streams
        self.members = members
    }
}

/// YouTube's Home and Subscriptions as last read with the phone's sign-in.
public struct StoredFeeds: Codable, Hashable, Sendable {
    public var recommended: [StoredVideo]
    public var subscriptions: [StoredVideo]
    public var channelAvatars: [String: String]
    public var loadedAt: Date?

    public init(recommended: [StoredVideo] = [], subscriptions: [StoredVideo] = [], channelAvatars: [String: String] = [:],
                loadedAt: Date? = nil) {
        self.recommended = recommended
        self.subscriptions = subscriptions
        self.channelAvatars = channelAvatars
        self.loadedAt = loadedAt
    }
}

/// The last check, for the Settings footer.
public struct CheckRecord: Codable, Hashable, Sendable {
    public var trigger: String
    public var startedAt: Date
    public var finishedAt: Date
    public var channelsChecked: Int
    public var errors: [String]
    /// Most of the channels couldn't be reached (the network): it doesn't count as the last check
    /// for the schedule (`CheckPlan.isDue`). Saved only when true, as on Android.
    public var offline: Bool

    public init(trigger: String, startedAt: Date, finishedAt: Date, channelsChecked: Int, errors: [String], offline: Bool = false) {
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.channelsChecked = channelsChecked
        self.errors = errors
        self.offline = offline
    }

    enum CodingKeys: String, CodingKey {
        case trigger, startedAt, finishedAt, channelsChecked, errors, offline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trigger = (try? c.decodeIfPresent(String.self, forKey: .trigger)) ?? ""
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        channelsChecked = (try? c.decodeIfPresent(Int.self, forKey: .channelsChecked)) ?? 0
        errors = (try? c.decodeIfPresent([String].self, forKey: .errors)) ?? []
        offline = (try? c.decodeIfPresent(Bool.self, forKey: .offline)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(finishedAt, forKey: .finishedAt)
        try c.encode(channelsChecked, forKey: .channelsChecked)
        try c.encode(errors, forKey: .errors)
        if offline { try c.encode(true, forKey: .offline) }
    }
}

/// Everything standalone mode keeps: standalone.json, one schema on both phones.
public struct StandaloneState: Codable, Equatable, Sendable {
    public var version = 1
    /// In the user's order.
    public var channels: [FollowedChannel] = []
    public var fetchedAt: [String: FeedTimes] = [:]
    /// Per channel, newest first, at most `StandaloneEngine.recentPerChannel`.
    public var recentVideos: [String: [StoredVideo]] = [:]
    public var groups: [ChannelGroup] = []
    /// Video id → `MemberAccess.stored`.
    public var memberAccess: [String: String] = [:]
    public var nonMemberChannels: [String: Date] = [:]
    public var noMembersPlaylist: [String: Date] = [:]
    public var accountFeeds: StoredFeeds?
    public var channelAvatars: [String: String] = [:]
    public var account = StandaloneAccount.signedOut
    public var syncWatchedWithYouTube = true
    public var youTubeHistory: [String] = []
    public var pendingYouTubeWatched: [String] = []
    public var lastWatchSync: Date?
    public var lastCheck: CheckRecord?
    public var lastPullAt: Date?
    public var failedCheckStreak = 0
    public var backoffUntil: Date?
    public var backoffMinutes = 0
    public var channelErrors: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        version = value(.version, 1)
        channels = value(.channels, [])
        fetchedAt = value(.fetchedAt, [:])
        recentVideos = value(.recentVideos, [:])
        groups = value(.groups, [])
        memberAccess = value(.memberAccess, [:])
        nonMemberChannels = value(.nonMemberChannels, [:])
        noMembersPlaylist = value(.noMembersPlaylist, [:])
        accountFeeds = try? c.decodeIfPresent(StoredFeeds.self, forKey: .accountFeeds)
        channelAvatars = value(.channelAvatars, [:])
        account = value(.account, .signedOut)
        syncWatchedWithYouTube = value(.syncWatchedWithYouTube, true)
        youTubeHistory = value(.youTubeHistory, [])
        pendingYouTubeWatched = value(.pendingYouTubeWatched, [])
        lastWatchSync = try? c.decodeIfPresent(Date.self, forKey: .lastWatchSync)
        lastCheck = try? c.decodeIfPresent(CheckRecord.self, forKey: .lastCheck)
        lastPullAt = try? c.decodeIfPresent(Date.self, forKey: .lastPullAt)
        failedCheckStreak = value(.failedCheckStreak, 0)
        backoffUntil = try? c.decodeIfPresent(Date.self, forKey: .backoffUntil)
        backoffMinutes = value(.backoffMinutes, 0)
        channelErrors = value(.channelErrors, [:])
    }

    public func access(_ videoId: String) -> MemberAccess? { memberAccess[videoId].flatMap(MemberAccess.init(stored:)) }

    public func isFollowing(_ channelId: String) -> Bool { channels.contains { $0.id == channelId } }

    static let knownKeys: Set<String> = Set(["version", "channels", "fetchedAt", "recentVideos", "groups", "memberAccess",
                                             "nonMemberChannels", "noMembersPlaylist", "accountFeeds", "channelAvatars", "account",
                                             "syncWatchedWithYouTube", "youTubeHistory", "pendingYouTubeWatched", "lastWatchSync",
                                             "lastCheck", "lastPullAt", "failedCheckStreak", "backoffUntil", "backoffMinutes",
                                             "channelErrors"])
}

/// Reads and writes standalone.json in Application Support: written atomically (a temporary
/// file, then a rename), dates as epoch milliseconds, keys sorted. Keys this build doesn't know
/// (a newer one's) are kept on save.
public final class StandaloneStore: @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()
    private var unknown: [String: Any] = [:]

    public static let fileName = "standalone.json"

    public init(directory: URL) {
        file = directory.appending(path: Self.fileName)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    public func load() -> StandaloneState {
        guard let data = try? Data(contentsOf: file) else { return StandaloneState() }
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lock.withLock { unknown = raw.filter { !StandaloneState.knownKeys.contains($0.key) } }
        }
        return (try? Self.decoder.decode(StandaloneState.self, from: data)) ?? StandaloneState()
    }

    public func save(_ state: StandaloneState) {
        guard let encoded = try? Self.encoder.encode(state) else { return }
        var data = encoded
        let extra = lock.withLock { unknown }
        if !extra.isEmpty, var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            for (key, value) in extra where object[key] == nil { object[key] = value }
            if let merged = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) { data = merged }
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: file)
        lock.withLock { unknown = [:] }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
