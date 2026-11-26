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

    func fetchPastStreams(channelId: String) async throws -> [Video] {
        try await PastStreamsFetcher(ytdlp: ytdlp).fetch(channelId: channelId)
    }

    func fetchMembersStreams(channelId: String, cookiesFile: URL) async throws -> MembersFeed {
        try await MembersFetcher(ytdlp: ytdlp).fetchStreams(channelId: channelId, cookiesFile: cookiesFile)
    }

    func fetchWatchHistory(cookiesFile: URL, limit: Int) async throws -> WatchHistory {
        try await WatchHistoryClient(ytdlp: ytdlp).fetch(cookiesFile: cookiesFile, limit: limit)
    }

    func markWatched(videoId: String, cookiesFile: URL) async throws {
        try await WatchHistoryClient(ytdlp: ytdlp).markWatched(videoId: videoId, cookiesFile: cookiesFile)
    }

    func fetchAccountFeeds(cookiesFile: URL, limit: Int) async throws -> AccountFeeds {
        try await AccountFeedClient(ytdlp: ytdlp).fetch(cookiesFile: cookiesFile, limit: limit)
    }

    func memberAccess(videoId: String, cookiesFile: URL) async throws -> MemberAccess {
        try await MemberAccessClient(ytdlp: ytdlp).access(videoId: videoId, cookiesFile: cookiesFile)
    }
}
