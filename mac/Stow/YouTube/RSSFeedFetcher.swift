import Foundation

struct RSSFeedFetcher: Sendable {
    /// Fetches https://www.youtube.com/feeds/videos.xml?playlist_id=<playlistId>.
    /// Throws `.channelNotFound(playlistId)` on 404 and `.network` for other failures.
    func fetch(playlistId: String) async throws -> [Video] {
        try await fetch(query: URLQueryItem(name: "playlist_id", value: playlistId))
    }

    /// The channel-wide feed (includes Shorts); used only to tell "no long-form videos"
    /// apart from "no such channel".
    func fetch(channelId: String) async throws -> [Video] {
        try await fetch(query: URLQueryItem(name: "channel_id", value: channelId))
    }

    private func fetch(query: URLQueryItem) async throws -> [Video] {
        var components = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")!
        components.queryItems = [query]
        let (data, status) = try await YouTubeHTTP.get(components.url!)
        switch status {
        case 200: return try RSSFeedParser.parse(data)
        case 404: throw StowError.channelNotFound(query.value ?? "")
        default: throw StowError.network("RSS feed for \(query.value ?? "") returned HTTP \(status)")
        }
    }
}
