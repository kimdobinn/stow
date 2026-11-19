import Foundation

/// The ASS text mpv draws over the alarm video (`osd-overlay`): a small clock in the top-right
/// corner, plus "1/3 · title · channel" in the top-left for a few seconds after each video starts.
enum OSDOverlay {
    static let id = 1
    /// The overlay's coordinate space height; font sizes below are relative to it.
    static let resolutionY = 720
    static let bannerDuration: Duration = .seconds(6)
    /// The clock shows minutes, so this keeps it at most this stale.
    static let refreshInterval: Duration = .seconds(15)
    static let maximumTitleLength = 90

    static func text(time: Date, banner: String?, timeZone: TimeZone = .current) -> String {
        let clock = "{\\an9\\fs30\\bord2\\shad1\\1a&H20&}" + escaped(clockString(time, timeZone: timeZone))
        guard let banner else { return clock }
        return clock + "\n{\\an7\\fs36\\bord2.5\\shad1}" + escaped(banner)
    }

    /// "1/3 · title · channel" for the video at `index` (0-based).
    static func banner(index: Int, count: Int, video: Video) -> String {
        var title = video.title
        if title.count > maximumTitleLength {
            title = String(title.prefix(maximumTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return "\(index + 1)/\(count) · \(title) · \(video.channelTitle)"
    }

    static func clockString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Plain text for an ASS event: no override blocks, escape sequences or line breaks.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\u{2060}")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
