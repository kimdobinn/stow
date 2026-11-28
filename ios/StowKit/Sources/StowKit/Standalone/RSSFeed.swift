import Foundation

/// YouTube's Atom feeds (`/feeds/videos.xml`), read without yt-dlp: a port of the Mac's
/// `RSSFeedFetcher` and `RSSFeedParser`.
///
/// The uploads feed is the `UULF…` playlist (long-form only), which is how Shorts and live
/// streams stay out of a channel's uploads, as on the Mac.
public enum RSSFeed {
    public static func url(playlistId: String) -> URL {
        URL(string: "https://www.youtube.com/feeds/videos.xml?playlist_id=\(playlistId)")!
    }

    public static func url(channelId: String) -> URL {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)")!
    }

    /// YouTube's playlist feeds answer 5xx now and then for a request or two: tried again this
    /// often (after half a second, then a second) before it counts.
    public static let serverRetries = 2

    /// The feed's videos. 404 throws `.notFound`, 429 `.rateLimited`, other errors `.server`.
    public static func fetch(_ url: URL, web: YouTubeWeb) async throws -> [Video] {
        let response = try await get(url, web: web)
        switch response.status {
        case 200: return try parse(response.data)
        case 404: throw StandaloneError.notFound(url.query ?? url.absoluteString)
        case 429: throw StandaloneError.rateLimited
        default: throw StandaloneError.server(response.status)
        }
    }

    /// A channel's public long-form uploads. When the UULF feed is missing (404), the channel-wide
    /// feed tells "no long-form videos" (200: an empty list) from "no such channel" (404: `.notFound`).
    public static func uploads(channelId: String, web: YouTubeWeb) async throws -> [Video] {
        do {
            return try await fetch(url(playlistId: PlaylistID.longForm(channelId: channelId)), web: web)
        } catch StandaloneError.notFound {
            let probe = try await get(url(channelId: channelId), web: web)
            return try probeAnswer(status: probe.status, channelId: channelId)
        }
    }

    /// A GET, tried again on a 5xx.
    static func get(_ url: URL, web: YouTubeWeb) async throws -> YouTubeWeb.Response {
        var response = try await web.get(url)
        var attempt = 0
        while (500...599).contains(response.status), attempt < serverRetries {
            attempt += 1
            try await Task.sleep(for: .milliseconds(500 * attempt))
            response = try await web.get(url)
        }
        return response
    }

    /// What the channel_id probe after a 404 means.
    static func probeAnswer(status: Int, channelId: String) throws -> [Video] {
        switch status {
        case 200: return []
        case 404: throw StandaloneError.notFound(channelId)
        case 429: throw StandaloneError.rateLimited
        default: throw StandaloneError.server(status)
        }
    }

    /// Parses an Atom feed (yt:videoId, yt:channelId, title, published, media:thumbnail,
    /// author/name). Videos get `liveStatus = "unknown"`, `isMembersOnly = false`.
    public static func parse(_ data: Data) throws -> [Video] {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawFeed else {
            let reason = parser.parserError?.localizedDescription ?? "not an Atom feed"
            throw StowError.parse("RSS feed: \(reason)")
        }
        return delegate.videos
    }
}

/// Playlist ids derived from a "UC…" channel id (the Mac's `PlaylistID`).
public enum PlaylistID {
    /// Public long-form uploads (no Shorts, no lives).
    public static func longForm(channelId: String) -> String { "UULF" + channelId.dropFirst(2) }
    /// Members-only long-form uploads (UUMF, not UUMO, which also lists members-only Shorts).
    public static func membersOnly(channelId: String) -> String { "UUMF" + channelId.dropFirst(2) }
    /// Public live streams, past and upcoming.
    public static func liveStreams(channelId: String) -> String { "UULV" + channelId.dropFirst(2) }
    /// Members-only live streams.
    public static func membersStreams(channelId: String) -> String { "UUMV" + channelId.dropFirst(2) }
}

private final class FeedDelegate: NSObject, XMLParserDelegate {
    private(set) var videos: [Video] = []
    private(set) var sawFeed = false

    private var feedAuthor: String?
    private var entry: [String: String]?
    private var thumbnail: String?
    private var path: [String] = []
    private var text = ""
    private let dateFormatter = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if path.isEmpty, name == "feed" { sawFeed = true }
        path.append(name)
        text = ""
        switch name {
        case "entry":
            entry = [:]
            thumbnail = nil
        case "media:thumbnail":
            thumbnail = attributes["url"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        let parent = path.dropLast().last

        if name == "name", parent == "author", path.count == 3 {
            feedAuthor = value // feed > author > name
            return
        }
        guard entry != nil else { return }
        switch (parent, name) {
        case ("entry", "yt:videoId"), ("entry", "yt:channelId"), ("entry", "title"), ("entry", "published"):
            entry?[name] = value
        case ("author", "name"):
            entry?["author"] = value
        case (_, "entry"):
            if let video = makeVideo() { videos.append(video) }
            entry = nil
        default:
            break
        }
    }

    private func makeVideo() -> Video? {
        guard let entry, let id = entry["yt:videoId"], !id.isEmpty, let channelId = entry["yt:channelId"] else { return nil }
        return Video(
            id: id,
            channelId: channelId,
            channelTitle: entry["author"] ?? feedAuthor ?? channelId,
            title: entry["title"] ?? id,
            publishedAt: entry["published"].flatMap(dateFormatter.date(from:)),
            thumbnailURL: thumbnail,
            isMembersOnly: false,
            liveStatus: "unknown"
        )
    }
}
