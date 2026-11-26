import Foundation

extension FeedVideo {
    /// As a `Video`, dated by YouTube's feed or else by `knownDate` (when Stow has the video).
    func video(knownDate: Date? = nil) -> Video {
        Video(id: id, channelId: channelId, channelTitle: channelTitle, title: title,
              publishedAt: timestamp.map { Date(timeIntervalSince1970: $0) } ?? knownDate,
              thumbnailURL: thumbnailURL ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
              isMembersOnly: isMembersOnly, liveStatus: wasLive ? .wasLive : (isLive ? .live : .none), duration: duration)
    }
}

enum Feeds {
    /// YouTube's Subscriptions feed with the followed channels' videos it doesn't list, newest
    /// first. The feed is already newest first: an undated entry sorts with the dated one above it
    /// (the phone does the same).
    static func subscriptions(feed: [Video], channelVideos: [Video]) -> [Video] {
        let inFeed = Set(feed.map(\.id))
        var last = Date.distantFuture
        var dated: [(video: Video, date: Date)] = feed.map { video in
            if let published = video.publishedAt { last = min(last, published) }
            return (video, last)
        }
        var seen = inFeed
        for video in channelVideos where seen.insert(video.id).inserted {
            dated.append((video, video.publishedAt ?? .distantPast))
        }
        return dated.enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }
            .map(\.element.video)
    }
}
