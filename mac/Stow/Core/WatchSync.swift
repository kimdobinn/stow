import Foundation

/// How Stow's watched videos follow the YouTube account's watch history. YouTube has no
/// "watched" API or notifications, so Stow polls the history every few minutes:
/// - Watched on YouTube → watched in Stow: entries that appeared at the top of the history
///   since the last poll (watching a video again moves it to the top).
/// - Watched in Stow → YouTube: yt-dlp --mark-watched, queued until it succeeds.
/// - Unwatched stays in Stow: YouTube only "unwatches" by deleting from the history.
enum WatchSync {
    /// Often enough to feel live, rare enough to be a few small requests per hour.
    static let interval: Duration = .seconds(5 * 60)
    static let historyLimit = 50
    /// History entries kept to compare the next poll against.
    static let anchorCount = 10
    /// Marks sent to YouTube per sync, so a long queue doesn't hold up reading the history.
    static let pushesPerSync = 10

    /// The entries of `history` watched since `previous` was fetched: those above the most
    /// recently watched video `previous` still shares with it. A first fetch is all new.
    static func newlyWatched(history: [String], previous: [String]) -> [String] {
        for anchor in previous.prefix(anchorCount) {
            if let index = history.firstIndex(of: anchor) { return Array(history[..<index]) }
        }
        return history
    }
}
