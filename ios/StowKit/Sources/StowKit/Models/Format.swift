import Foundation

/// Text the Android app shows for counts, lengths and sizes, so both phones read the same.
public enum Format {
    /// 950, 1.2K, 34K, 1.5M: YouTube's short counts.
    public static func shortCount(_ n: Int) -> String {
        func trimmed(_ value: Double) -> String {
            let rounded = (value * 10).rounded(.down) / 10
            return rounded == rounded.rounded(.down) ? String(Int(rounded)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        }
        switch n {
        case ..<1_000: return "\(n)"
        case ..<10_000: return trimmed(Double(n) / 1_000) + "K"
        case ..<1_000_000: return "\(n / 1_000)K"
        case ..<10_000_000: return trimmed(Double(n) / 1_000_000) + "M"
        default: return "\(n / 1_000_000)M"
        }
    }

    /// "1 video", "3 videos".
    public static func count(_ n: Int, _ noun: String) -> String { "\(n) \(n == 1 ? noun : noun + "s")" }

    /// "1 h 5 min", "42 min", "<1 min", "0 min".
    public static func minutes(seconds: Int) -> String {
        if (1...59).contains(seconds) { return "<1 min" }
        let minutes = seconds / 60
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// "1:02:03", "4:05".
    public static func duration(ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func bytes(_ bytes: Int64) -> String {
        let gb = Double(1 << 30), mb = Double(1 << 20)
        if Double(bytes) >= gb { return String(format: "%.1f GB", Double(bytes) / gb) }
        if Double(bytes) >= mb { return String(format: "%.0f MB", Double(bytes) / mb) }
        return "\(bytes / 1024) KB"
    }
}
