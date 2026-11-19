import Foundation

struct SponsorSegment: Equatable, Sendable {
    var category: String
    var start: TimeInterval
    var end: TimeInterval
}

/// SponsorBlock (sponsor.ajay.app): crowd-sourced segments to skip. Any failure means no skipping.
enum SponsorBlock {
    static let categories = ["sponsor", "selfpromo", "interaction", "intro", "outro"]
    /// Segments shorter than this aren't worth a seek.
    static let minimumLength: TimeInterval = 1
    /// Don't seek when already this close to the segment's end (a keyframe seek can land just short of it).
    static let endTolerance: TimeInterval = 0.5

    static func url(videoId: String) -> URL {
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        let categoryList = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        components.queryItems = [URLQueryItem(name: "videoID", value: videoId),
                                 URLQueryItem(name: "categories", value: categoryList)]
        return components.url!
    }

    static func segments(videoId: String) async -> [SponsorSegment] {
        var request = URLRequest(url: url(videoId: videoId))
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }

    /// Skip segments, sorted by start; malformed entries and non-skip actions are dropped.
    static func parse(_ data: Data) -> [SponsorSegment] {
        struct Entry: Decodable {
            var segment: [Double]
            var category: String
            var actionType: String?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            guard entry.segment.count == 2, entry.actionType ?? "skip" == "skip",
                  entry.segment[1] - entry.segment[0] >= minimumLength else { return nil }
            return SponsorSegment(category: entry.category, start: entry.segment[0], end: entry.segment[1])
        }
        .sorted { $0.start < $1.start }
    }

    /// The index of the segment to skip at `position`: one that contains it, isn't nearly over and
    /// hasn't been skipped already in this video (so seeking back into it doesn't loop).
    static func segmentToSkip(at position: TimeInterval, in segments: [SponsorSegment], skipped: Set<Int>) -> Int? {
        segments.indices.first { index in
            let segment = segments[index]
            return !skipped.contains(index) && position >= segment.start && position < segment.end - endTolerance
        }
    }
}
