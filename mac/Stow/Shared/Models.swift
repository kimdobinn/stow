import Foundation

// Value types shared by every module. FROZEN: request changes from the architect.
// Types persisted to JSON decode tolerantly (missing keys fall back to defaults)
// because settings.json is meant to be hand-edited.

/// A YouTube channel as resolved from user input or the subscriptions list.
struct ChannelInfo: Codable, Hashable, Identifiable, Sendable {
    /// Channel id, always "UC" + 22 chars.
    var id: String
    var title: String
    /// "@handle" including the "@", when known.
    var handle: String?
    var avatarURL: URL?
}

/// A channel the user follows, as stored in settings.json.
struct Channel: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var handle: String?
    var avatarURL: URL?
    /// Include this channel's new videos in the morning alarm.
    var morning: Bool

    init(info: ChannelInfo, morning: Bool = true) {
        id = info.id
        title = info.title
        handle = info.handle
        avatarURL = info.avatarURL
        self.morning = morning
    }

    var url: URL { URL(string: "https://www.youtube.com/channel/\(id)")! }

    private enum CodingKeys: String, CodingKey { case id, title, handle, avatarURL, morning }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        avatarURL = try c.decodeIfPresent(URL.self, forKey: .avatarURL)
        morning = try c.decodeIfPresent(Bool.self, forKey: .morning) ?? true
    }
}

/// Whether the saved sign-in can watch a members-only video: channels can have membership levels,
/// and a video for a higher level is locked even to members.
enum MemberAccess: Codable, Equatable, Sendable {
    case watchable
    /// Needs a higher membership level (YouTube's name for it, when it gives one). Without a
    /// level, the account isn't a member of the channel at all.
    case locked(level: String?)
    /// Was for members first and is public now.
    case nowPublic

    var isLocked: Bool { if case .locked = self { true } else { false } }
    var canWatch: Bool { self == .watchable || self == .nowPublic }
}

enum LiveStatus: String, Codable, Sendable {
    /// Regular upload.
    case none
    case live
    case upcoming
    /// A finished live stream (archived).
    case wasLive
    /// The source cannot tell (e.g. RSS).
    case unknown
}

struct Video: Codable, Hashable, Identifiable, Sendable {
    /// YouTube video id (11 chars).
    var id: String
    var channelId: String
    var channelTitle: String
    var title: String
    /// Nil when the source does not provide it (yt-dlp --flat-playlist).
    var publishedAt: Date?
    var thumbnailURL: URL?
    var isMembersOnly: Bool
    var liveStatus: LiveStatus
    /// Seconds; known for past streams and members-only videos (yt-dlp lists it), not RSS uploads.
    var duration: TimeInterval? = nil

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

struct InboxItem: Codable, Hashable, Identifiable, Sendable {
    var video: Video
    var foundAt: Date

    var id: String { video.id }
}

enum CheckTrigger: String, Codable, Sendable {
    case launch, scheduled, wake, manual, channelAdded, signIn
    /// Pulled down to refresh on the phone.
    case phone
    /// The alarm's prep step refreshing feeds before it picks videos.
    case alarm
}

struct CheckResult: Codable, Equatable, Sendable {
    var trigger: CheckTrigger
    var startedAt: Date
    var finishedAt: Date
    var channelsChecked: Int
    var newVideos: Int
    /// Human-readable problems, e.g. "TQQQCRAZY: members feed failed: ...".
    var errors: [String]

    var isOK: Bool { errors.isEmpty }
}

enum LogLevel: String, Codable, Sendable {
    case info, warning, error
}

struct LogEntry: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    var level: LogLevel
    var message: String

    init(level: LogLevel, message: String, date: Date = .now) {
        id = UUID()
        self.date = date
        self.level = level
        self.message = message
    }
}

enum SignInState: String, Codable, Sendable {
    /// Not determined yet (app just launched).
    case unknown
    case signedOut
    case signedIn
    /// Cookies exist but YouTube rejected them (reported by yt-dlp).
    case expired
}

/// settings.json. New top-level sections are added as new keys with defaults so older files keep decoding.
struct AppSettings: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var channels: [Channel]
    var checkIntervalMinutes: Int
    var launchAtLogin: Bool
    var alarm: AlarmSettings
    /// Keep watched videos in step with the signed-in YouTube account's watch history.
    var syncWatchedWithYouTube: Bool

    static let `default` = AppSettings(schemaVersion: 1, channels: [], checkIntervalMinutes: 30, launchAtLogin: true)

    init(schemaVersion: Int, channels: [Channel], checkIntervalMinutes: Int, launchAtLogin: Bool,
         alarm: AlarmSettings = .default, syncWatchedWithYouTube: Bool = true) {
        self.schemaVersion = schemaVersion
        self.channels = channels
        self.checkIntervalMinutes = checkIntervalMinutes
        self.launchAtLogin = launchAtLogin
        self.alarm = alarm
        self.syncWatchedWithYouTube = syncWatchedWithYouTube
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, channels, checkIntervalMinutes, launchAtLogin, alarm, syncWatchedWithYouTube
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        channels = try c.decodeIfPresent([Channel].self, forKey: .channels) ?? d.channels
        checkIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .checkIntervalMinutes) ?? d.checkIntervalMinutes
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        syncWatchedWithYouTube = try c.decodeIfPresent(Bool.self, forKey: .syncWatchedWithYouTube) ?? d.syncWatchedWithYouTube
        // A hand edit that breaks "alarm" (e.g. not an object) must not cost the channel list.
        do {
            alarm = try c.decodeIfPresent(AlarmSettings.self, forKey: .alarm) ?? d.alarm
        } catch {
            alarm = d.alarm
            decoder.settingsIssues?.add("\"alarm\" isn't an object; using the default alarm settings.")
        }
    }
}

/// A channel's video feeds.
enum FeedKind: String, Codable, CaseIterable, Sendable {
    /// Public long-form uploads (UULF RSS).
    case uploads
    /// Members-only uploads (UUMF via yt-dlp).
    case members
    /// Finished public live streams (the channel's Live tab via yt-dlp, UULV RSS for titles and dates).
    case streams
    /// Finished members-only live streams (UUMV via yt-dlp).
    case memberStreams

    /// Past streams are kept for the phone's channel pages, but a channel's back catalogue of them
    /// isn't news: the first fetch of these puts nothing in the Inbox.
    var seedsInbox: Bool { self == .uploads || self == .members }
}

/// state.json: machine-written, human-readable.
struct AppState: Codable, Equatable, Sendable {
    /// channelId -> video ids already seen (newest first, capped by Core).
    /// A channel with no entry has never been checked: the first-add rule applies.
    var seenVideoIds: [String: [String]]
    /// channelId -> feeds fetched successfully at least once. A feed missing here gets
    /// the first-fetch rule (its 2 newest are new) instead of flooding the Inbox.
    var checkedFeeds: [String: [FeedKind]]
    /// Newest first.
    var inbox: [InboxItem]
    /// channelId -> the channel's most recent videos from its feeds (newest first, capped by Core),
    /// for the Inbox's "Recent" feed.
    var recentVideos: [String: [Video]]
    var lastCheck: CheckResult?
    /// Consecutive checks that had errors (other than an expired sign-in).
    var failedCheckStreak: Int
    /// Videos the alarm started, newest first (capped by Core). The alarm never picks these
    /// again, except through a `replayLatest` fallback rule.
    var alarmPlayedIds: [String]
    /// Watched videos, newest first (capped by Core): played to at least 90% by the alarm,
    /// marked in Stow, or watched on YouTube (from the account's watch history).
    var watchedIds: [String]
    /// Videos marked watched in Stow that YouTube's watch history doesn't have yet, oldest first.
    var pendingYouTubeWatched: [String]
    /// The account's watch history as last fetched (most recently watched first). The next
    /// fetch's entries above these are what was watched on YouTube in between.
    var youTubeHistory: [String]
    var lastWatchSync: Date?
    var phone: PhoneSyncState
    /// What the saved sign-in's membership level can do with members-only videos, by video id.
    var memberAccess: [String: MemberAccess]
    var lastAlarmRun: AlarmRunRecord?
    /// The alarm time of the newest scheduled run (played or skipped), so a test run that
    /// replaces `lastAlarmRun` can't make that alarm fire again after a relaunch.
    var lastScheduledAlarm: Date?
    /// Channels whose members-only videos the account can't watch at all (it isn't a member), and
    /// when that was found: their members feeds aren't fetched for a week at a time.
    var nonMemberChannels: [String: Date] = [:]
    /// Videos found watchable before `nowPublic` existed were checked again (once).
    var accessRechecked = false
    /// Pictures of channels in YouTube's feeds that Stow doesn't follow (the feeds list none),
    /// looked up from each channel's page once.
    var channelAvatars: [String: URL] = [:]

    static let empty = AppState(seenVideoIds: [:], inbox: [], lastCheck: nil)

    init(seenVideoIds: [String: [String]], checkedFeeds: [String: [FeedKind]] = [:], inbox: [InboxItem],
         recentVideos: [String: [Video]] = [:], lastCheck: CheckResult?, failedCheckStreak: Int = 0,
         alarmPlayedIds: [String] = [], watchedIds: [String] = [], pendingYouTubeWatched: [String] = [],
         youTubeHistory: [String] = [], lastWatchSync: Date? = nil, phone: PhoneSyncState = .empty,
         memberAccess: [String: MemberAccess] = [:], lastAlarmRun: AlarmRunRecord? = nil,
         lastScheduledAlarm: Date? = nil) {
        self.seenVideoIds = seenVideoIds
        self.checkedFeeds = checkedFeeds
        self.inbox = inbox
        self.recentVideos = recentVideos
        self.lastCheck = lastCheck
        self.failedCheckStreak = failedCheckStreak
        self.alarmPlayedIds = alarmPlayedIds
        self.watchedIds = watchedIds
        self.pendingYouTubeWatched = pendingYouTubeWatched
        self.youTubeHistory = youTubeHistory
        self.lastWatchSync = lastWatchSync
        self.phone = phone
        self.memberAccess = memberAccess
        self.lastAlarmRun = lastAlarmRun
        self.lastScheduledAlarm = lastScheduledAlarm
    }

    private enum CodingKeys: String, CodingKey {
        case seenVideoIds, checkedFeeds, inbox, recentVideos, lastCheck, failedCheckStreak, alarmPlayedIds, watchedIds,
             pendingYouTubeWatched, youTubeHistory, lastWatchSync, phone, memberAccess, lastAlarmRun, lastScheduledAlarm,
             nonMemberChannels, accessRechecked, channelAvatars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seenVideoIds = try c.decodeIfPresent([String: [String]].self, forKey: .seenVideoIds) ?? [:]
        checkedFeeds = try c.decodeIfPresent([String: [FeedKind]].self, forKey: .checkedFeeds) ?? [:]
        inbox = try c.decodeIfPresent([InboxItem].self, forKey: .inbox) ?? []
        recentVideos = try c.decodeIfPresent([String: [Video]].self, forKey: .recentVideos) ?? [:]
        lastCheck = try c.decodeIfPresent(CheckResult.self, forKey: .lastCheck)
        failedCheckStreak = try c.decodeIfPresent(Int.self, forKey: .failedCheckStreak) ?? 0
        alarmPlayedIds = try c.decodeIfPresent([String].self, forKey: .alarmPlayedIds) ?? []
        watchedIds = try c.decodeIfPresent([String].self, forKey: .watchedIds) ?? []
        pendingYouTubeWatched = try c.decodeIfPresent([String].self, forKey: .pendingYouTubeWatched) ?? []
        youTubeHistory = try c.decodeIfPresent([String].self, forKey: .youTubeHistory) ?? []
        lastWatchSync = try c.decodeIfPresent(Date.self, forKey: .lastWatchSync)
        phone = (try? c.decodeIfPresent(PhoneSyncState.self, forKey: .phone)) ?? .empty
        memberAccess = (try? c.decodeIfPresent([String: MemberAccess].self, forKey: .memberAccess)) ?? [:]
        // Written by a newer build with an outcome this one doesn't know: forget it, keep the rest.
        lastAlarmRun = try? c.decodeIfPresent(AlarmRunRecord.self, forKey: .lastAlarmRun)
        lastScheduledAlarm = (try? c.decodeIfPresent(Date.self, forKey: .lastScheduledAlarm))
            ?? lastAlarmRun.flatMap { $0.trigger == .scheduled ? $0.scheduledFor : nil }
        nonMemberChannels = (try? c.decodeIfPresent([String: Date].self, forKey: .nonMemberChannels)) ?? [:]
        accessRechecked = (try? c.decodeIfPresent(Bool.self, forKey: .accessRechecked)) ?? false
        channelAvatars = (try? c.decodeIfPresent([String: URL].self, forKey: .channelAvatars)) ?? [:]
    }
}

enum StowError: Error, Equatable, LocalizedError {
    case toolNotFound(String)
    case processFailed(tool: String, exitCode: Int32, stderr: String)
    case timedOut(tool: String)
    /// YouTube rejected the exported cookies; the user must sign in again.
    case authExpired
    case notSignedIn
    case invalidChannelInput(String)
    case channelNotFound(String)
    case channelAlreadyAdded(String)
    case network(String)
    case parse(String)
    /// No CoreAudio output matches (name or UID).
    case audioDeviceNotFound(String)
    /// A CoreAudio / AVFoundation call failed.
    case audio(String)
    /// mpv couldn't start or its IPC connection failed.
    case player(String)
    case bluetooth(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool): "\(tool) not found (looked in /opt/homebrew/bin, /usr/local/bin, /usr/bin)."
        case .processFailed(let tool, let code, let stderr): "\(tool) failed (exit \(code)): \(stderr)"
        case .timedOut(let tool): "\(tool) timed out."
        case .authExpired: "YouTube sign-in expired. Sign in again."
        case .notSignedIn: "Not signed in to YouTube."
        case .invalidChannelInput(let input): "Not a channel URL, @handle or channel id: \(input)"
        case .channelNotFound(let input): "Channel not found: \(input)"
        case .channelAlreadyAdded(let title): "\(title) is already added."
        case .network(let message): "Network error: \(message)"
        case .parse(let message): "Unexpected response: \(message)"
        case .audioDeviceNotFound(let name): "Audio output not found: \(name)"
        case .audio(let message): "Audio error: \(message)"
        case .player(let message): "Player error: \(message)"
        case .bluetooth(let message): "Bluetooth error: \(message)"
        }
    }
}
