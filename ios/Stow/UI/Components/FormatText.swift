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

    /// As Android's DateUtils says it: "Just now", "5 minutes ago", "Yesterday", "3 days ago",
    /// then the date ("Nov 3", or "Nov 3, 2024" in another year).
    static func ago(_ date: Date?, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return seconds > -60 ? "Just now" : dateText(date, now: now, calendar: calendar, locale: locale) }
        if seconds < 7 * 86_400 {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = seconds >= 86_400 ? .named : .numeric
            let text = formatter.localizedString(for: date, relativeTo: now)
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        return dateText(date, now: now, calendar: calendar, locale: locale)
    }

    private static func dateText(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if !sameYear { style = style.year() }
        return date.formatted(style)
    }
}
