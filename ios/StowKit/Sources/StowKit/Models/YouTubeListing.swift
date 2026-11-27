import Foundation

/// YouTube lists from yt-dlp's `--flat-playlist -J` answer: search results (`ytsearchN:`) or a
/// channel's tab (…/videos, …/streams).
public enum YouTubeListing {
    /// The channel's picture, on a channel tab.
    public static func channelAvatar(_ json: String) -> String? {
        guard let root = try? JSONObject(parsing: json) else { return nil }
        return root.objects("thumbnails")?.first { $0.string("id") == "avatar_uncropped" }?.string("url")
    }

    /// The channel's name, on a channel tab.
    public static func channelTitle(_ json: String) -> String? {
        guard let root = try? JSONObject(parsing: json) else { return nil }
        return root.string("channel") ?? root.string("uploader")
    }

    /// Videos only, in YouTube's order: no Shorts, and no live or upcoming streams (only finished
    /// ones). A channel tab's videos don't name their channel; they get the tab's.
    public static func parse(_ json: String) throws -> [Video] {
        let root = try JSONObject(parsing: json)
        guard let entries = root.array("entries") else { return [] }
        let pageChannelId = root.string("channel_id").flatMap { $0.hasPrefix("UC") ? $0 : nil } ?? ""
        let pageChannel = pageChannelId.isEmpty ? "" : (root.string("channel") ?? root.string("uploader") ?? "")
        return entries.compactMap { entry -> Video? in
            guard let o = JSONObject(any: entry), let id = o.string("id"), id.utf16.count == 11 else { return nil }
            if (o.string("url") ?? "").contains("/shorts/") { return nil }
            let live = o.string("live_status")
            if live == "is_live" || live == "is_upcoming" || live == "post_live" { return nil }
            // The widest picture; on a tie, the first (as Kotlin's maxByOrNull picks).
            var widest: JSONObject?
            for thumbnail in o.objects("thumbnails") ?? [] where widest == nil || (thumbnail.int("width") ?? 0) > (widest?.int("width") ?? 0) {
                widest = thumbnail
            }
            let video = Video(
                id: id,
                channelId: o.string("channel_id") ?? pageChannelId,
                channelTitle: o.string("channel") ?? o.string("uploader") ?? pageChannel,
                title: o.string("title") ?? id,
                publishedAt: o.number("timestamp").map(Date.init(epochSeconds:)),
                thumbnailURL: widest?.string("url") ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
                isMembersOnly: o.string("availability") == "subscriber_only",
                liveStatus: live,
                durationSeconds: o.int("duration")
            )
            return video.isShort ? nil : video
        }
    }
}
