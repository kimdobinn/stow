import Foundation

struct MembersFetcher: Sendable {
    let ytdlp: YTDLP

    static let limit = 10

    /// yt-dlp --cookies <copy> --flat-playlist -J --playlist-end 10 on the members playlist.
    /// Returns no videos when the channel has no members playlist. Live and upcoming entries are
    /// dropped. Throws `.notSignedIn` when the cookies file is missing.
    func fetch(channelId: String, cookiesFile: URL) async throws -> MembersFeed {
        // Parallel runs must not clobber each other or the file Account owns.
        let cookies = try CookieCopy.make(of: cookiesFile)
        defer { try? FileManager.default.removeItem(at: cookies) }

        let playlistId = PlaylistID.membersOnly(channelId: channelId)
        let playlist = "https://www.youtube.com/playlist?list=\(playlistId)"
        // yt-dlp's titles come back auto-translated and undated; the members RSS feed has the
        // original titles and publish dates, so it's used to correct them where it can.
        async let feed = try? RSSFeedFetcher().fetch(playlistId: playlistId)
        let output: YTDLP.Output
        do {
            output = try await ytdlp.run(["--cookies", cookies.path, "--flat-playlist", "-J",
                                          "--playlist-end", String(Self.limit), playlist])
        } catch StowError.processFailed(_, _, let stderr) where YTDLP.classify(stderr: stderr) == .unavailable {
            return MembersFeed(videos: [])
        }
        let videos = try Self.parse(playlistJSON: output.stdout, channelId: channelId)
            .filter { $0.liveStatus != .live && $0.liveStatus != .upcoming }
        return MembersFeed(videos: Self.applyOriginalMetadata(videos, from: await feed ?? []),
                           cookiesRejected: output.cookiesRejected)
    }

    /// Replaces each video's title, date and channel title with the RSS feed's original ones.
    static func applyOriginalMetadata(_ videos: [Video], from feed: [Video]) -> [Video] {
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

    /// Parses yt-dlp -J playlist output. Entries get `isMembersOnly = true`.
    /// Private and deleted placeholders are skipped.
    static func parse(playlistJSON: Data, channelId: String) throws -> [Video] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let playlist: Playlist?
        do {
            playlist = try decoder.decode(Playlist?.self, from: playlistJSON)
        } catch {
            throw StowError.parse("yt-dlp playlist JSON: \(error.localizedDescription)")
        }
        guard let playlist else { return [] }
        return (playlist.entries ?? []).compactMap { $0 }.filter(\.isViewable).prefix(limit).map { entry in
            Video(
                id: entry.id,
                channelId: entry.channelId ?? playlist.channelId ?? channelId,
                channelTitle: entry.channel ?? playlist.channel ?? channelId,
                title: entry.title ?? entry.id,
                publishedAt: (entry.timestamp ?? entry.releaseTimestamp).map(Date.init(timeIntervalSince1970:)),
                thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg"),
                isMembersOnly: true,
                liveStatus: liveStatus(entry.liveStatus)
            )
        }
    }

    private static func liveStatus(_ value: String?) -> LiveStatus {
        switch value {
        case "not_live": .none
        case "is_live": .live
        case "is_upcoming": .upcoming
        case "was_live", "post_live": .wasLive
        default: .unknown
        }
    }
}

private struct Playlist: Decodable {
    var channel: String?
    var channelId: String?
    var entries: [Entry?]?
}

private struct Entry: Decodable {
    var id: String
    var title: String?
    var channel: String?
    var channelId: String?
    var timestamp: Double?
    var releaseTimestamp: Double?
    var liveStatus: String?
    var availability: String?

    var isViewable: Bool {
        availability != "private" && title != "[Private video]" && title != "[Deleted video]"
    }
}
