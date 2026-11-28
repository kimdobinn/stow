import Foundation

/// Whether the account's membership level can watch a members-only video (the Mac's
/// `MemberAccess` and `MemberAccessClient`): yt-dlp looks the video up with the cookies, and
/// YouTube either serves it or names the level it needs.
public enum MemberAccess: Hashable, Sendable {
    case watchable
    /// Needs a higher level (YouTube's name for it, when it gives one). Without a level, the
    /// account isn't a member of the channel at all.
    case locked(level: String?)
    /// Was for members first and is public now.
    case nowPublic

    public var isLocked: Bool { if case .locked = self { true } else { false } }
    public var canWatch: Bool { self == .watchable || self == .nowPublic }

    /// "watchable", "nowPublic", "locked" or "locked:<level>" (standalone.json).
    public var stored: String {
        switch self {
        case .watchable: "watchable"
        case .nowPublic: "nowPublic"
        case .locked(nil): "locked"
        case .locked(let level?): "locked:\(level)"
        }
    }

    public init?(stored: String) {
        switch stored {
        case "watchable": self = .watchable
        case "nowPublic": self = .nowPublic
        case "locked": self = .locked(level: nil)
        default:
            guard stored.hasPrefix("locked:") else { return nil }
            let level = String(stored.dropFirst("locked:".count))
            self = .locked(level: level.isEmpty ? nil : level)
        }
    }

    /// A video that plays: still for members, or public now (members-first videos open up later).
    public static func fromLookup(_ json: String) -> MemberAccess {
        switch (try? JSONObject(parsing: json))?.string("availability") {
        case "public", "unlisted": .nowPublic
        default: .watchable
        }
    }

    /// What a failed lookup says about access: the level a locked video needs, or (when it failed
    /// only after YouTube let the account in, picking a stream) watchable. Nil when it can't tell.
    public static func fromError(_ text: String) -> MemberAccess? {
        if let range = text.range(of: "members on level: ") {
            let rest = text[range.upperBound...]
            let end = rest.range(of: " (or any higher level)")?.lowerBound
                ?? rest.firstIndex(where: { $0 == "." || $0.isNewline }) ?? rest.endIndex
            let level = rest[..<end].trimmingCharacters(in: .whitespaces)
            return .locked(level: level.isEmpty ? nil : level)
        }
        let lowered = text.lowercased()
        if lowered.contains("join this channel to get access") || lowered.contains("members-only content")
            || lowered.contains("this video is not available") || lowered.contains("video unavailable") {
            return .locked(level: nil)
        }
        if lowered.contains("requested format is not available") || lowered.contains("only images are available") {
            return .watchable
        }
        return nil
    }
}

/// How watched videos follow the YouTube account's history (the Mac's `WatchSync`).
public enum WatchSync {
    public static let historyLimit = 50
    /// History entries kept to compare the next read against.
    public static let anchorCount = 10
    /// Marks sent to YouTube per sync.
    public static let pushesPerSync = 10
    public static let interval: TimeInterval = 15 * 60

    /// The entries of `history` watched since `previous` was read: those above the most recently
    /// watched video `previous` still shares with it. A first read is all new.
    public static func newlyWatched(history: [String], previous: [String]) -> [String] {
        for anchor in previous.prefix(anchorCount) {
            if let index = history.firstIndex(of: anchor) { return Array(history[..<index]) }
        }
        return history
    }

    /// The history playlist's video ids, most recent first, without repeats.
    public static func parseHistory(_ json: String) throws -> [String] {
        let root = try JSONObject(parsing: json)
        var seen = Set<String>()
        return (root.array("entries") ?? []).compactMap { JSONObject(any: $0)?.string("id") }.filter { seen.insert($0).inserted }
    }
}
