import Foundation

/// The signed-in account's YouTube Home recommendations and Subscriptions feed, through yt-dlp
/// (`:ytrec`, `:ytsubs`) with the same cookies as the members-only feeds.
struct AccountFeedClient: Sendable {
    let ytdlp: YTDLP

    func fetch(cookiesFile: URL, limit: Int) async throws -> AccountFeeds {
        async let recommended = list(":ytrec", cookiesFile: cookiesFile, limit: limit)
        async let subscriptions = list(":ytsubs", cookiesFile: cookiesFile, limit: limit)
        return AccountFeeds(recommended: try await recommended, subscriptions: try await subscriptions)
    }

    private func list(_ feed: String, cookiesFile: URL, limit: Int) async throws -> [FeedVideo] {
        let cookies = try CookieCopy.make(of: cookiesFile)
        defer { try? FileManager.default.removeItem(at: cookies) }
        let output = try await ytdlp.run(["--cookies", cookies.path, "--flat-playlist", "-J",
                                          "--playlist-end", String(limit), feed], timeout: .seconds(60))
        if output.cookiesRejected { throw StowError.authExpired }
        return try Self.parse(feedJSON: output.stdout)
    }

    /// Anything this short is a Short, whatever the feed calls it.
    static let shortsMaxSeconds: Double = 60

    /// The feed's long-form videos and finished streams in order, without repeats: no Mixes or
    /// playlists, no Shorts, nothing live now or still to come (none of that can be downloaded).
    static func parse(feedJSON: Data) throws -> [FeedVideo] {
        let feed: Feed?
        do {
            feed = try JSONDecoder().decode(Feed?.self, from: feedJSON)
        } catch {
            throw StowError.parse("yt-dlp feed JSON: \(error.localizedDescription)")
        }
        var seen = Set<String>()
        return (feed?.entries ?? []).compactMap { entry -> FeedVideo? in
            guard let entry, entry.id.count == 11, let channelId = entry.channel_id,
                  !(entry.url ?? "").contains("/shorts/"), (entry.duration ?? .infinity) > shortsMaxSeconds,
                  !["is_upcoming", "is_live", "post_live"].contains(entry.live_status ?? ""),
                  seen.insert(entry.id).inserted else { return nil }
            let thumbnail = entry.thumbnails?.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url.flatMap(URL.init(string:))
            return FeedVideo(id: entry.id, channelId: channelId,
                             channelTitle: entry.channel ?? entry.uploader ?? "",
                             title: entry.title ?? "",
                             duration: entry.duration,
                             thumbnailURL: thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg"),
                             isMembersOnly: entry.availability == "subscriber_only",
                             isLive: false, wasLive: entry.live_status == "was_live",
                             timestamp: entry.timestamp)
        }
    }
}

private struct Feed: Decodable {
    var entries: [Entry?]?

    struct Entry: Decodable {
        var id: String
        var url: String?
        var title: String?
        var channel: String?
        var channel_id: String?
        var uploader: String?
        var duration: Double?
        var timestamp: Double?
        var live_status: String?
        var availability: String?
        var thumbnails: [Thumbnail]?
    }

    struct Thumbnail: Decodable {
        var url: String?
        var width: Int?
    }
}
