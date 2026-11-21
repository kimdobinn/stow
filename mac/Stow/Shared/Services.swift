import Foundation

// Module boundaries. FROZEN: request changes from the architect.
// Core depends only on these protocols; concrete types are wired up in StowApp.

/// Implemented by YouTube/YouTubeClient. Stateless; safe to call from any context.
protocol YouTubeService: Sendable {
    /// Resolves a channel URL (any youtube.com/channel|@|c|user form), "@handle",
    /// bare handle or "UC..." id.
    /// Throws `.invalidChannelInput`, `.channelNotFound`, `.network`.
    func resolveChannel(input: String) async throws -> ChannelInfo

    /// Public long-form uploads (UULF RSS playlist), newest first. No Shorts.
    func fetchPublicVideos(channelId: String) async throws -> [Video]

    /// Members-only long-form uploads (UUMF playlist via yt-dlp --cookies; UUMO would also
    /// list members-only Shorts), newest first, at most 10. Returns no videos when the channel
    /// has no members playlist. When YouTube rejects the cookies but still lists the playlist,
    /// returns the videos with `cookiesRejected` set. Throws `.authExpired` when the rejection
    /// made the run fail, `.notSignedIn` when `cookiesFile` is missing, `.network`,
    /// `.toolNotFound`, `.processFailed`, `.timedOut`.
    func fetchMembersVideos(channelId: String, cookiesFile: URL) async throws -> MembersFeed

    /// The signed-in account's watch history (youtube.com/feed/history via yt-dlp), most
    /// recently watched first, at most `limit` video ids. Throws like `fetchMembersVideos`.
    func fetchWatchHistory(cookiesFile: URL, limit: Int) async throws -> WatchHistory

    /// Adds the video to the account's watch history (yt-dlp --mark-watched). Throws
    /// `.processFailed` when the video is unavailable, otherwise like `fetchMembersVideos`.
    func markWatched(videoId: String, cookiesFile: URL) async throws

    /// The signed-in account's YouTube Home recommendations and Subscriptions feed (yt-dlp
    /// :ytrec / :ytsubs), long-form videos only, at most `limit` each. Throws like
    /// `fetchMembersVideos`.
    func fetchAccountFeeds(cookiesFile: URL, limit: Int) async throws -> AccountFeeds
}

/// What YouTube itself would show the account: its Home recommendations and Subscriptions feed.
struct AccountFeeds: Codable, Equatable, Sendable {
    var recommended: [FeedVideo]
    var subscriptions: [FeedVideo]
}

/// A video in a YouTube feed (yt-dlp --flat-playlist lists no upload dates).
struct FeedVideo: Codable, Equatable, Sendable {
    var id: String
    var channelId: String
    var channelTitle: String
    var title: String
    /// Seconds.
    var duration: Double?
    var thumbnailURL: URL?
    var isMembersOnly: Bool
    var isLive: Bool
}

struct WatchHistory: Sendable {
    /// Most recently watched first, no duplicates.
    var videoIds: [String]
    var cookiesRejected = false
}

struct MembersFeed: Sendable {
    var videos: [Video]
    /// yt-dlp warned that the cookies are no longer valid (the sign-in expired).
    var cookiesRejected = false
}

/// Implemented by Account/AccountManager.
@MainActor
protocol AccountService: AnyObject {
    /// Inspects the dedicated web data store. When signed in, re-exports
    /// `AppPaths.cookiesFile` (0600) so yt-dlp gets fresh cookies. Never returns `.expired`
    /// (only yt-dlp can detect that) or `.unknown`.
    func refresh() async -> SignInState

    /// Shows the sign-in window and returns once it closes (the window closes itself after a
    /// sign-in is detected). Returns true, after exporting cookies, only when the user signed in
    /// while the window was open; an existing (possibly expired) session doesn't count.
    func signIn() async -> Bool

    /// Clears the dedicated data store and deletes the cookies file.
    func signOut() async

    /// The signed-in user's subscriptions, in YouTube's order. Throws `.notSignedIn`.
    func fetchSubscriptions() async throws -> [ChannelInfo]
}
