import Foundation
import StowKit

/// The text the Android app shows under a video (ui/Format.kt), on top of StowKit's `Format`.
extension Format {
    /// "Channel · 3 days ago" (· "4:12" in calm mode) (· "Members only").
    static func meta(_ item: VideoItem, withDuration: Bool = false, now: Date = .now) -> String {
        [item.video.channelTitle, whenText(item, now: now),
         withDuration && item.durationMs > 0 ? duration(ms: item.durationMs) : "",
         item.video.isMembersOnly ? "Members only" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Without the channel (on a channel's own page): "3 days ago · Members only".
    static func metaWithoutChannel(_ item: VideoItem, withDuration: Bool = false, now: Date = .now) -> String {
        [whenText(item, now: now),
         withDuration && item.durationMs > 0 ? duration(ms: item.durationMs) : "",
         item.video.isMembersOnly ? "Members only" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "3 days ago", or "Streamed 3 days ago" for a past live stream.
    static func whenText(_ item: VideoItem, now: Date = .now) -> String {
        let ago = ago(item.video.publishedAt, now: now)
        guard item.video.isPastStream else { return ago }
        return ago.isEmpty ? "Streamed" : "Streamed " + ago.prefix(1).lowercased() + ago.dropFirst()
    }

    /// As YouTube says it: "Just now", "5 minutes ago", "3 days ago", "2 weeks ago", "4 months ago",
    /// "1 year ago". Never a full date: most dates from YouTube's listings are only that rough.
    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        let day = 86_400
        // YouTube's rough dates ("1 year ago") come back rounded to the day, up to a day short.
        let rough = seconds + day
        let (n, unit): (Int, String) = switch seconds {
        case ..<3_600: (seconds / 60, "minute")
        case ..<day: (seconds / 3_600, "hour")
        case ..<(7 * day): (seconds / day, "day")
        case _ where rough < 30 * day: (rough / (7 * day), "week")
        case _ where rough < 360 * day: (rough / (30 * day), "month")
        default: (max(rough / (365 * day), 1), "year")
        }
        return "\(n) \(unit)\(n == 1 ? "" : "s") ago"
    }
}
