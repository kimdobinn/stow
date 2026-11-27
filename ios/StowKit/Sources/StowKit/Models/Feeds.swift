import Foundation

/// Pure list logic for Home, Subscriptions and channel pages.
public enum Feeds {
    /// YouTube's Subscriptions feed (newest first, mostly undated) with your Mac channels' videos
    /// it doesn't have (dated) slotted in by date. An undated feed video counts as being as old as
    /// the dated one above it, so YouTube's own order is kept.
    public static func subscriptions(feed: [VideoItem], channelVideos: [VideoItem]) -> [VideoItem] {
        let ids = Set(feed.map(\.id))
        var last = Double.greatestFiniteMagnitude
        var dated: [(item: VideoItem, time: Double)] = feed.map { item in
            if let time = item.video.publishedAt?.timeIntervalSince1970 { last = min(last, time) }
            return (item, last)
        }
        var seen = Set<String>()
        for item in channelVideos where !ids.contains(item.id) && seen.insert(item.id).inserted {
            dated.append((item, item.video.publishedAt?.timeIntervalSince1970 ?? 0))
        }
        return stableSorted(dated) { $0.time > $1.time }.map(\.item)
    }

    /// A group's videos: from its channels, newest first (undated ones last).
    public static func group(_ group: ChannelGroup, all: [VideoItem]) -> [VideoItem] {
        let ids = group.channelIds
        var seen = Set<String>()
        let videos = all.filter { ids.contains($0.video.channelId) && seen.insert($0.id).inserted }
        return newestFirst(videos)
    }

    /// A channel's other videos, and its past live streams.
    public static func split(_ videos: [VideoItem]) -> (uploads: [VideoItem], streams: [VideoItem]) {
        (videos.filter { !$0.video.isPastStream }, videos.filter { $0.video.isPastStream })
    }

    /// Rough download size, when yt-dlp can't say: about 3 Mbit/s for 1080p H.264 with AAC.
    public static func estimatedBytes(durationMs: Int) -> Int64 { Int64(durationMs / 1000) * 3_000_000 / 8 }

    /// Newest first by upload date, else by when it was sent (undated last), keeping the given
    /// order among equals.
    public static func newestFirst(_ items: [VideoItem]) -> [VideoItem] {
        stableSorted(items) { ($0.sortDate ?? .distantPast) > ($1.sortDate ?? .distantPast) }
    }

    /// Downloads in the order picked under Downloads.
    public static func sorted(_ items: [VideoItem], by sort: DownloadSort) -> [VideoItem] {
        func time(_ date: Date?, missing: Double = 0) -> Double { date?.timeIntervalSince1970 ?? missing }
        switch sort {
        case .recentlyDownloaded:
            return stableSorted(items) { time($0.local?.downloadedAt ?? $0.local?.updatedAt) > time($1.local?.downloadedAt ?? $1.local?.updatedAt) }
        case .newest:
            return stableSorted(items) { time($0.video.publishedAt) > time($1.video.publishedAt) }
        case .oldest:
            return stableSorted(items) { time($0.video.publishedAt, missing: .greatestFiniteMagnitude) < time($1.video.publishedAt, missing: .greatestFiniteMagnitude) }
        case .channel:
            return stableSorted(items) { a, b in
                let (x, y) = (a.video.channelTitle.lowercased(), b.video.channelTitle.lowercased())
                return x != y ? x < y : time(a.video.publishedAt) > time(b.video.publishedAt)
            }
        case .longest: return stableSorted(items) { $0.durationMs > $1.durationMs }
        case .shortest: return stableSorted(items) { $0.durationMs < $1.durationMs }
        case .title: return stableSorted(items) { $0.video.title.lowercased() < $1.video.title.lowercased() }
        }
    }

    public static func filtered(_ items: [VideoItem], by filter: WatchFilter) -> [VideoItem] {
        switch filter {
        case .all: items
        case .unwatched: items.filter { !$0.watched }
        case .watched: items.filter(\.watched)
        }
    }

    static func stableSorted<T>(_ values: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        values.enumerated().sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
