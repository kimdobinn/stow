import Foundation

struct YouTubeClient: YouTubeService {
    private let ytdlp = YTDLP()
    private let rss = RSSFeedFetcher()

    func resolveChannel(input: String) async throws -> ChannelInfo {
        try await ChannelResolver(ytdlp: ytdlp).resolve(input: input)
    }

    func fetchPublicVideos(channelId: String) async throws -> [Video] {
        do {
            return try await rss.fetch(playlistId: PlaylistID.longForm(channelId: channelId))
        } catch StowError.channelNotFound {
            // UULF 404s when a channel has no long-form uploads; that's only an error
            // if the channel itself is gone.
            _ = try await rss.fetch(channelId: channelId)
            return []
        }
    }

    func fetchMembersVideos(channelId: String, cookiesFile: URL) async throws -> MembersFeed {
        try await MembersFetcher(ytdlp: ytdlp).fetch(channelId: channelId, cookiesFile: cookiesFile)
    }
}
