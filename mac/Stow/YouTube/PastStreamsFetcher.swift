import Foundation

/// A channel's finished public live streams: yt-dlp lists the Live tab with each stream's state and
/// length; the UULV RSS feed has the original titles and the dates.
struct PastStreamsFetcher: Sendable {
    let ytdlp: YTDLP

    static let limit = 15

    func fetch(channelId: String) async throws -> [Video] {
        async let feed = try? RSSFeedFetcher().fetch(playlistId: PlaylistID.liveStreams(channelId: channelId))
        let output: YTDLP.Output
        do {
            output = try await ytdlp.run(["--flat-playlist", "-J", "--playlist-end", String(Self.limit),
                                          "https://www.youtube.com/channel/\(channelId)/streams"], timeout: .seconds(60))
        } catch StowError.processFailed(_, _, let stderr) where YTDLP.classify(stderr: stderr) == .unavailable {
            return []   // No Live tab.
        }
        return Self.streams(fromTabJSON: output.stdout, channelId: channelId, feed: await feed)
    }

    /// The finished streams in `json` (yt-dlp -J of a Live tab). With the RSS `feed`, only the
    /// streams it lists (it has their dates), with its titles.
    static func streams(fromTabJSON json: Data, channelId: String, feed: [Video]?) -> [Video] {
        guard let tab = try? JSONDecoder().decode(Tab.self, from: json) else { return [] }
        let byId = Dictionary((feed ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return (tab.entries ?? []).compactMap { entry -> Video? in
            guard let entry, entry.id.count == 11, entry.live_status == "was_live",
                  seen.insert(entry.id).inserted else { return nil }
            let original = byId[entry.id]
            if feed != nil, original == nil { return nil }
            return Video(id: entry.id, channelId: channelId,
                         channelTitle: original?.channelTitle ?? tab.channel ?? "",
                         title: original?.title ?? entry.title ?? entry.id,
                         publishedAt: original?.publishedAt ?? entry.timestamp.map(Date.init(timeIntervalSince1970:)),
                         thumbnailURL: original?.thumbnailURL ?? URL(string: "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg"),
                         isMembersOnly: false, liveStatus: .wasLive, duration: entry.duration)
        }
    }

    private struct Tab: Decodable {
        var channel: String?
        var entries: [Entry?]?
    }

    private struct Entry: Decodable {
        var id: String
        var title: String?
        var live_status: String?
        var duration: Double?
        var timestamp: Double?
    }
}
