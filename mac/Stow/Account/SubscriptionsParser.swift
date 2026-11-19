import Foundation

/// Pure JSON walker for YouTube's /feed/channels data. Instead of following a fixed path
/// (which YouTube reshuffles often) it collects every "channelRenderer" object anywhere in
/// the tree, plus the first continuation token.
enum SubscriptionsParser {
    /// Extracts channels from ytInitialData of /feed/channels (or a continuation
    /// response), plus the next continuation token if more pages exist.
    static func parse(_ json: Data) throws -> (channels: [ChannelInfo], continuation: String?) {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: json)
        } catch {
            throw StowError.parse("subscriptions JSON: \(error.localizedDescription)")
        }
        var walker = Walker()
        walker.visit(root)
        return (walker.channels, walker.continuation)
    }

    private struct Walker {
        var channels: [ChannelInfo] = []
        var continuation: String?
        private var seen: Set<String> = []

        mutating func visit(_ node: Any) {
            if let array = node as? [Any] {
                array.forEach { visit($0) }
                return
            }
            guard let object = node as? [String: Any] else { return }
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                switch key {
                case "channelRenderer":
                    if let renderer = value as? [String: Any], let channel = SubscriptionsParser.channel(from: renderer),
                       seen.insert(channel.id).inserted {
                        channels.append(channel)
                    }
                case "continuationItemRenderer", "nextContinuationData":
                    if continuation == nil, let token = SubscriptionsParser.continuationToken(in: value) {
                        continuation = token
                    }
                default:
                    visit(value)
                }
            }
        }
    }

    private static func channel(from renderer: [String: Any]) -> ChannelInfo? {
        guard let id = renderer["channelId"] as? String, id.hasPrefix("UC") else { return nil }
        let title = text(renderer["title"]) ?? id
        return ChannelInfo(id: id, title: title, handle: handle(in: renderer), avatarURL: avatarURL(in: renderer))
    }

    /// The handle lives in the browse endpoint's canonicalBaseUrl ("/@name", percent-encoded for
    /// non-ASCII) or, in the current layout, in subscriberCountText ("@name").
    private static func handle(in renderer: [String: Any]) -> String? {
        let endpoint = renderer["navigationEndpoint"] as? [String: Any]
        let browse = endpoint?["browseEndpoint"] as? [String: Any]
        if let base = browse?["canonicalBaseUrl"] as? String, base.hasPrefix("/@") {
            let raw = String(base.dropFirst())
            return raw.removingPercentEncoding ?? raw
        }
        if let text = text(renderer["subscriberCountText"]), text.hasPrefix("@"), !text.contains(" ") {
            return text
        }
        return nil
    }

    /// The widest thumbnail; YouTube serves protocol-relative "//yt3…" URLs.
    private static func avatarURL(in renderer: [String: Any]) -> URL? {
        let thumbnail = renderer["thumbnail"] as? [String: Any]
        let thumbnails = thumbnail?["thumbnails"] as? [[String: Any]] ?? []
        let best = thumbnails.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
        guard let raw = best?["url"] as? String else { return nil }
        return URL(string: raw.hasPrefix("//") ? "https:" + raw : raw)
    }

    /// YouTube text is either {"simpleText": "…"} or {"runs": [{"text": "…"}, …]}.
    private static func text(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let simple = object["simpleText"] as? String { return simple }
        let runs = (object["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        return runs.flatMap { $0.isEmpty ? nil : $0.joined() }
    }

    /// Finds `continuationCommand.token` (current) or `continuation` (legacy nextContinuationData).
    private static func continuationToken(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let command = object["continuationCommand"] as? [String: Any], let token = command["token"] as? String {
                return token
            }
            if let token = object["continuation"] as? String { return token }
            for key in object.keys.sorted() {
                if let token = continuationToken(in: object[key]!) { return token }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let token = continuationToken(in: item) { return token }
            }
        }
        return nil
    }
}
