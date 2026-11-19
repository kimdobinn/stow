import Foundation

struct VideoDiff: Equatable {
    /// Videos for the Inbox: each feed's new videos in feed order (public first).
    var newVideos: [Video]
    /// Updated seen ids for the channel, newest first, capped.
    var seenVideoIds: [String]
    /// The channel's feeds that have now been fetched at least once.
    var checkedFeeds: Set<FeedKind>
}

enum VideoDiffer {
    /// How many videos a newly added channel, or a feed fetched for the first time, adds to the Inbox.
    static let firstCheckNewCount = 2
    /// Seen ids kept per channel. Feeds return at most ~25 ids per check and fetched ids
    /// always stay at the front, so this only drops ids long gone from every feed.
    static let seenLimit = 200

    /// Diffs one channel's fetched feeds (each newest first) against what was seen before.
    /// - A feed in `checkedFeeds` contributes every unseen video, however many piled up.
    /// - A new channel (`seen == nil`) contributes its 2 newest videos across all feeds. Feeds
    ///   without dates (members) rank below dated ones, since they can't be shown to be newer.
    /// - A feed fetched for the first time on a known channel (e.g. members after signing in)
    ///   contributes its 2 newest, not its back catalog.
    /// Live and upcoming videos are neither new nor seen.
    static func diff(sources: [FeedKind: [Video]], seen: [String]?, checkedFeeds: Set<FeedKind>) -> VideoDiff {
        var result = VideoDiff(newVideos: [], seenVideoIds: seen ?? [], checkedFeeds: checkedFeeds)
        var newChannelCandidates: [Video] = []
        for kind in FeedKind.allCases {
            guard let fetched = sources[kind] else { continue }
            let videos = eligible(fetched)
            let seenSet = Set(result.seenVideoIds)
            let unseen = videos.filter { !seenSet.contains($0.id) }
            if checkedFeeds.contains(kind) {
                result.newVideos += unseen
            } else if seen == nil {
                newChannelCandidates += unseen
            } else {
                result.newVideos += unseen.prefix(firstCheckNewCount)
            }
            result.seenVideoIds = unique(videos.map(\.id) + result.seenVideoIds)
            result.checkedFeeds.insert(kind)
        }
        result.newVideos += newest(newChannelCandidates, count: firstCheckNewCount)
        result.seenVideoIds = Array(result.seenVideoIds.prefix(seenLimit))
        return result
    }

    /// The `count` newest by date; undated videos rank last and keep their feed order.
    private static func newest(_ videos: [Video], count: Int) -> [Video] {
        videos.enumerated()
            .sorted { a, b in
                let (dateA, dateB) = (a.element.publishedAt ?? .distantPast, b.element.publishedAt ?? .distantPast)
                return dateA != dateB ? dateA > dateB : a.offset < b.offset
            }
            .prefix(count)
            .map(\.element)
    }

    private static func eligible(_ videos: [Video]) -> [Video] {
        var ids = Set<String>()
        return videos.filter { $0.liveStatus != .live && $0.liveStatus != .upcoming && ids.insert($0.id).inserted }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
