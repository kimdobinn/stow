import Foundation

enum RSSFeedParser {
    /// Parses a YouTube Atom feed (yt:videoId, yt:channelId, title, published,
    /// media:thumbnail, author/name). Videos get `liveStatus = .unknown`, `isMembersOnly = false`.
    static func parse(_ data: Data) throws -> [Video] {
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

private final class FeedDelegate: NSObject, XMLParserDelegate {
    private(set) var videos: [Video] = []
    private(set) var sawFeed = false

    private var feedAuthor: String?
    private var entry: [String: String]?
    private var thumbnail: URL?
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
            thumbnail = attributes["url"].flatMap(URL.init(string:))
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
            liveStatus: .unknown
        )
    }
}
