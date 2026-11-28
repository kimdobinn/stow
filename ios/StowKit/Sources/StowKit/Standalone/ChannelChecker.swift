import Foundation

/// A channel's feeds.
public enum FeedKind: String, Sendable, CaseIterable {
    /// Public long-form uploads (UULF RSS).
    case uploads
    /// Finished public live streams (the Live tab with UULV RSS).
    case streams
    /// Members-only uploads (UUMF).
    case members
    /// Members-only finished streams (UUMV).
    case memberStreams
}

/// What one channel's feeds gave during a check (the Mac's `ChannelFetch`).
public struct ChannelFetchResult: Sendable {
    public var channelId: String
    /// The feeds that answered, each newest first.
    public var sources: [FeedKind: [Video]] = [:]
    public var errors: [String] = []
    /// YouTube rejected the cookies on a members feed.
    public var authExpired = false
    /// A members feed was read with accepted cookies.
    public var membersSucceeded = false
    /// The channel has no members playlist (UUMF unavailable).
    public var noMembersPlaylist = false
    /// Neither the uploads feed nor the channel feed exists.
    public var notFound = false
    /// HTTP 429 or 5xx: the rest of the check waits (backoff).
    public var rateLimited = false
    /// Every feed failed because of the network.
    public var offline = false
    /// Videos whose dates are yt-dlp's approximate ones ("3 weeks ago", to the day), not a
    /// feed's: they never replace a date already known (`RecentMerge.merge`).
    public var approximateDates: Set<String> = []

    public init(channelId: String) {
        self.channelId = channelId
    }
}

/// At most `permits` calls at a time (yt-dlp runs: two at once).
public actor Limiter {
    private let permits: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(permits: Int) {
        self.permits = permits
    }

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if running < permits {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Reads one channel's feeds: a port of the Mac's `ChannelFetch`, with RSS over plain HTTP and
/// the rest through yt-dlp.
public struct ChannelChecker: Sendable {
    public let web: YouTubeWeb
    public let youtube: YouTubeTool
    public let ytdlp: Limiter

    public static let streamsLimit = 15
    public static let membersLimit = 10

    public init(web: YouTubeWeb, youtube: YouTubeTool, ytdlp: Limiter = Limiter(permits: 2)) {
        self.web = web
        self.youtube = youtube
        self.ytdlp = ytdlp
    }

    public func fetch(_ channel: FollowedChannel, feeds: CheckPlan.Feeds, cookies: URL?) async -> ChannelFetchResult {
        var result = ChannelFetchResult(channelId: channel.id)
        var networkFailures = 0
        var attempts = 0
        func failed(_ feed: String, _ error: Error) {
            if error is CancellationError { return }
            if Self.isRateLimit(error) {
                // YouTube answered (asking to slow down): that's backoff, not being offline.
                result.rateLimited = true
            } else if YouTubeFailure.classify(error) == .network {
                networkFailures += 1
            }
            result.errors.append("\(channel.title): \(feed) failed: \(YouTubeFailure.message(error))")
        }
        if feeds.uploads {
            attempts += 1
            do {
                let (videos, approximate) = try await uploads(channelId: channel.id)
                result.sources[.uploads] = videos
                if approximate { result.approximateDates.formUnion(videos.map(\.id)) }
            } catch StandaloneError.notFound {
                result.notFound = true
                result.errors.append("\(channel.title): Channel not found")
            } catch {
                failed("uploads", error)
            }
        }
        if feeds.streams, !result.rateLimited, !result.notFound {
            attempts += 1
            do {
                let (videos, approximate) = try await streams(channelId: channel.id)
                result.sources[.streams] = videos
                result.approximateDates.formUnion(approximate)
            } catch {
                failed("past streams", error)
            }
        }
        if feeds.members, let cookies, !result.rateLimited, !result.notFound {
            let members = await members(channel, cookies: cookies)
            result.sources.merge(members.sources) { _, new in new }
            result.authExpired = members.authExpired
            result.membersSucceeded = members.membersSucceeded
            result.noMembersPlaylist = members.noMembersPlaylist
            result.rateLimited = result.rateLimited || members.rateLimited
            result.errors += members.errors
            result.approximateDates.formUnion(members.approximateDates)
        }
        result.offline = attempts > 0 && networkFailures == attempts
        return result
    }

    /// The UULF feed, or when YouTube's playlist feeds keep answering 5xx (they do, for hours at a
    /// time), the Videos tab through yt-dlp, which has no Shorts or live streams either. The tab's
    /// dates are approximate (`approximate`), put in the tab's order.
    func uploads(channelId: String) async throws -> (videos: [Video], approximate: Bool) {
        do {
            return (try await RSSFeed.uploads(channelId: channelId, web: web), false)
        } catch StandaloneError.server(let status) where (500...599).contains(status) {
            let youtube = youtube
            let url = "https://www.youtube.com/channel/\(channelId)/videos"
            do {
                let listing = try await ytdlp.run { try await youtube.flatListing(url, count: Self.uploadsFallbackLimit, cookies: nil) }
                return (RecentMerge.inListedOrder(try YouTubeListing.parse(listing.json)), true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The feed's answer is the one that counts (backoff).
                throw StandaloneError.server(status)
            }
        }
    }

    public static let uploadsFallbackLimit = 30

    /// 429 and 5xx answers, and yt-dlp's "HTTP Error 429".
    static func isRateLimit(_ error: Error) -> Bool {
        switch error as? StandaloneError {
        case .rateLimited: return true
        case .server(let status): return status == 429 || (500...599).contains(status)
        default: return YouTubeFailure.isRateLimited(YouTubeFailure.message(error))
        }
    }

    // Past streams

    /// The Live tab through yt-dlp, with the UULV feed's titles and dates. No Live tab: none.
    /// Without the feed, the tab's dates are approximate: those videos' ids come back too.
    func streams(channelId: String) async throws -> (videos: [Video], approximate: Set<String>) {
        let web = web
        async let feed = try? RSSFeed.fetch(RSSFeed.url(playlistId: PlaylistID.liveStreams(channelId: channelId)), web: web)
        let youtube = youtube
        let url = "https://www.youtube.com/channel/\(channelId)/streams"
        let listing: FlatListing
        do {
            listing = try await ytdlp.run { try await youtube.flatListing(url, count: Self.streamsLimit, cookies: nil) }
        } catch {
            if YouTubeFailure.classify(error) == .unavailable { return ([], []) }
            throw error
        }
        guard Self.hasStates(tabJSON: listing.json) else {
            // An older yt-dlp lists the Live tab without each entry's state: nothing tells past
            // streams from live or upcoming ones. Not counted as read, so the next check asks again.
            throw StandaloneError.other("yt-dlp gave no stream states")
        }
        let rss = await feed
        let videos = Self.streams(fromTabJSON: listing.json, channelId: channelId, feed: rss)
        guard rss == nil else { return (videos, []) }
        return (RecentMerge.inListedOrder(videos), Set(videos.map(\.id)))
    }

    /// Whether a Live tab's listing says each entry's `live_status` (an empty one does too).
    public static func hasStates(tabJSON json: String) -> Bool {
        guard let tab = try? JSONObject(parsing: json), let entries = tab.array("entries") else { return true }
        if entries.isEmpty { return true }
        return entries.contains { JSONObject(any: $0)?.string("live_status") != nil }
    }

    /// The finished streams in a Live tab's listing (the Mac's `PastStreamsFetcher.streams`). With
    /// the RSS `feed`, only the streams it lists (it has their dates), with its titles.
    public static func streams(fromTabJSON json: String, channelId: String, feed: [Video]?) -> [Video] {
        guard let tab = try? JSONObject(parsing: json) else { return [] }
        let byId = Dictionary((feed ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return (tab.array("entries") ?? []).compactMap { raw -> Video? in
            guard let entry = JSONObject(any: raw), let id = entry.string("id"), id.utf16.count == 11,
                  entry.string("live_status") == "was_live", seen.insert(id).inserted else { return nil }
            let original = byId[id]
            if feed != nil, original == nil { return nil }
            return Video(id: id, channelId: channelId,
                         channelTitle: original?.channelTitle ?? tab.string("channel") ?? "",
                         title: original?.title ?? entry.string("title") ?? id,
                         publishedAt: original?.publishedAt ?? entry.number("timestamp").map(Date.init(epochSeconds:)),
                         thumbnailURL: original?.thumbnailURL ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
                         isMembersOnly: false, liveStatus: "wasLive", durationSeconds: entry.int("duration"))
        }
    }

    // Members

    private func members(_ channel: FollowedChannel, cookies: URL) async -> ChannelFetchResult {
        var result = ChannelFetchResult(channelId: channel.id)
        func failed(_ feed: String, _ error: Error) {
            if error is CancellationError { return }
            if Self.isRateLimit(error) { result.rateLimited = true }
            result.errors.append("\(channel.title): \(feed) failed: \(YouTubeFailure.message(error))")
        }
        do {
            let (videos, approximate, rejected) = try await membersPlaylist(PlaylistID.membersOnly(channelId: channel.id), channelId: channel.id, cookies: cookies)
            result.sources[.members] = videos.filter { $0.liveStatus != "is_live" && $0.liveStatus != "is_upcoming" }
            result.approximateDates.formUnion(approximate)
            result.authExpired = rejected
            result.membersSucceeded = !rejected
        } catch {
            switch YouTubeFailure.classify(error) {
            case .auth: result.authExpired = true
            case .unavailable: result.noMembersPlaylist = true
            default: failed("members feed", error)
            }
            return result
        }
        guard !result.authExpired else { return result }
        do {
            let (videos, approximate, rejected) = try await membersPlaylist(PlaylistID.membersStreams(channelId: channel.id), channelId: channel.id, cookies: cookies)
            result.sources[.memberStreams] = videos.filter(\.isPastStream)
            result.approximateDates.formUnion(approximate)
            if rejected { result.authExpired = true }
        } catch {
            switch YouTubeFailure.classify(error) {
            case .auth: result.authExpired = true
            case .unavailable: break
            default: failed("members streams", error)
            }
        }
        return result
    }

    /// The playlist's videos, the ones whose dates are yt-dlp's (not in the RSS feed), and whether
    /// the cookies were rejected.
    private func membersPlaylist(_ playlistId: String, channelId: String, cookies: URL) async throws -> ([Video], Set<String>, Bool) {
        let web = web
        // yt-dlp's titles come back translated and undated; the members RSS feed has the originals.
        async let feed = try? RSSFeed.fetch(RSSFeed.url(playlistId: playlistId), web: web)
        let youtube = youtube
        let url = "https://www.youtube.com/playlist?list=\(playlistId)"
        let listing = try await ytdlp.run { try await youtube.flatListing(url, count: Self.membersLimit, cookies: cookies) }
        let videos = try Self.parseMembers(listing.json, channelId: channelId)
        let rss = await feed ?? []
        let inFeed = Set(rss.map(\.id))
        let approximate = Set(videos.map(\.id).filter { !inFeed.contains($0) })
        return (Self.applyOriginalMetadata(videos, from: rss), approximate, listing.cookiesRejected)
    }

    /// A members playlist's listing (the Mac's `MembersFetcher.parse`): `isMembersOnly`, private
    /// and deleted placeholders skipped. "post_live" counts as live.
    public static func parseMembers(_ json: String, channelId: String) throws -> [Video] {
        let root = try JSONObject(parsing: json)
        let entries = (root.array("entries") ?? []).compactMap { JSONObject(any: $0) }
        return entries.filter { entry in
            entry.string("id") != nil && entry.string("availability") != "private"
                && entry.string("title") != "[Private video]" && entry.string("title") != "[Deleted video]"
        }.prefix(membersLimit).map { entry in
            let id = entry.string("id")!
            return Video(id: id,
                         channelId: entry.string("channel_id") ?? root.string("channel_id") ?? channelId,
                         channelTitle: entry.string("channel") ?? root.string("channel") ?? channelId,
                         title: entry.string("title") ?? id,
                         publishedAt: (entry.number("timestamp") ?? entry.number("release_timestamp")).map(Date.init(epochSeconds:)),
                         thumbnailURL: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
                         isMembersOnly: true,
                         liveStatus: liveStatus(entry.string("live_status")),
                         durationSeconds: entry.int("duration"))
        }
    }

    static func liveStatus(_ value: String?) -> String? {
        switch value {
        case "not_live": nil
        case "is_live", "post_live": "is_live"
        case "is_upcoming": "is_upcoming"
        case "was_live": "wasLive"
        default: "unknown"
        }
    }

    /// Each video's title, date and channel title from the RSS feed, where it has them.
    public static func applyOriginalMetadata(_ videos: [Video], from feed: [Video]) -> [Video] {
        let byId = Dictionary(feed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return videos.map { video in
            guard let original = byId[video.id] else { return video }
            var corrected = video
            corrected.title = original.title
            corrected.publishedAt = original.publishedAt ?? video.publishedAt
            corrected.channelTitle = original.channelTitle
            return corrected
        }
    }

    // Member access

    /// What the account's level can do with a members-only video: yt-dlp looks it up with the cookies.
    public func access(videoId: String, cookies: URL) async throws -> MemberAccess {
        let youtube = youtube
        do {
            let json = try await ytdlp.run { try await youtube.info(videoId: videoId, cookies: cookies) }
            return MemberAccess.fromLookup(json)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let text = YouTubeFailure.message(error)
            if let access = MemberAccess.fromError(text) { return access }
            if YouTubeFailure.classify(text) == .auth { throw StandaloneError.auth }
            throw error
        }
    }
}

/// The Mac's `mergeRecent` and visibility rules, for a channel's recent videos.
public enum RecentMerge {
    /// Fresh feed entries replace stored ones (titles change); videos that dropped out of a feed
    /// stay until the cap. Undated entries take the time they were first seen, so they sort as
    /// newest. Newest first, at most `cap`.
    ///
    /// A date in `approximate` (yt-dlp's "3 weeks ago", when the RSS feeds are down) is used only
    /// for a video without one, so a known date doesn't move between checks; a feed's date always wins.
    public static func merge(_ stored: [StoredVideo], with fetched: [Video], now: Date, cap: Int,
                             approximate: Set<String> = []) -> [StoredVideo] {
        var byId = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for video in fetched {
            let old = byId[video.id]
            let foundAt = old?.foundAt ?? now
            var fresh = StoredVideo(video, foundAt: foundAt)
            fresh.publishedAt = approximate.contains(video.id)
                ? old?.publishedAt ?? video.publishedAt ?? foundAt
                : video.publishedAt ?? old?.publishedAt ?? foundAt
            fresh.duration = video.durationSeconds ?? old?.duration
            fresh.thumbnailURL = video.thumbnailURL ?? old?.thumbnailURL
            byId[video.id] = fresh
        }
        return Array(byId.values
            .sorted { ($0.publishedAt ?? .distantPast, $1.id) > ($1.publishedAt ?? .distantPast, $0.id) }
            .prefix(cap))
    }

    /// A listing's approximate dates (yt-dlp rounds "3 weeks ago" to a day, so many videos share
    /// one) made to follow the listing's own order, newest first: a video dated no earlier than the
    /// one listed before it is put a minute before that one. Undated videos stay undated.
    public static func inListedOrder(_ videos: [Video]) -> [Video] {
        var previous: Date?
        return videos.map { video in
            guard var date = video.publishedAt else { return video }
            if let previous, date >= previous { date = previous.addingTimeInterval(-60) }
            previous = date
            var ordered = video
            ordered.publishedAt = date
            return ordered
        }
    }

    /// Uses the channel's own title and id, whatever the feed said.
    public static func normalized(_ video: Video, channel: FollowedChannel) -> Video {
        var video = video
        video.channelId = channel.id
        video.channelTitle = channel.title
        return video
    }

    /// What the screens show: members-only videos only once the account's level can watch them,
    /// and "public now" ones as public (the Mac's `phoneRecentVideos`).
    public static func visible(_ videos: [Video], access: (String) -> MemberAccess?) -> [Video] {
        videos.compactMap { video in
            guard video.isMembersOnly else { return video }
            switch access(video.id) {
            case .watchable: return video
            case .nowPublic:
                var open = video
                open.isMembersOnly = false
                return open
            default: return nil
            }
        }
    }
}
