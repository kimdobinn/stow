#if DEBUG
import Foundation

// Fakes for SwiftUI previews only; never used by the running app.

private struct PreviewYouTube: YouTubeService {
    func resolveChannel(input: String) async throws -> ChannelInfo { throw StowError.channelNotFound(input) }
    func fetchPublicVideos(channelId: String) async throws -> [Video] { [] }
    func fetchMembersVideos(channelId: String, cookiesFile: URL) async throws -> MembersFeed { MembersFeed(videos: []) }
    func fetchPastStreams(channelId: String) async throws -> [Video] { [] }
    func fetchMembersStreams(channelId: String, cookiesFile: URL) async throws -> MembersFeed { MembersFeed(videos: []) }
    func fetchWatchHistory(cookiesFile: URL, limit: Int) async throws -> WatchHistory { WatchHistory(videoIds: []) }
    func markWatched(videoId: String, cookiesFile: URL) async throws {}
    func fetchAccountFeeds(cookiesFile: URL, limit: Int) async throws -> AccountFeeds {
        AccountFeeds(recommended: [], subscriptions: [])
    }

    func memberAccess(videoId: String, cookiesFile: URL) async throws -> MemberAccess { .watchable }
}

@MainActor
private final class PreviewAccount: AccountService {
    func refresh() async -> SignInState { .signedOut }
    func signIn() async -> Bool { true }
    func signOut() async {}
    func fetchSubscriptions() async throws -> [ChannelInfo] {
        [
            ChannelInfo(id: "UC-XMoeMXbYrMlvmyLSwDd3g", title: "Jack Hopkins", handle: "@JackhopkinsCEO"),
            ChannelInfo(id: "UCeUP5Kb-EDDplwAi0H02XlA", title: "TQQQCRAZY", handle: "@TQQQCRAZY"),
        ]
    }
}

extension AppModel {
    static var preview: AppModel { AppModel(youtube: PreviewYouTube(), account: PreviewAccount(), alarmServices: .sample) }
}

extension InboxItem {
    static let preview = InboxItem(
        video: Video(
            id: "dQw4w9WgXcQ",
            channelId: "UCeUP5Kb-EDDplwAi0H02XlA",
            channelTitle: "TQQQCRAZY",
            title: "멤버십 전용: 오늘의 시장 정리와 내일 전략 — a long title that wraps onto two lines",
            publishedAt: .now.addingTimeInterval(-3600 * 3),
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"),
            isMembersOnly: true,
            liveStatus: .none
        ),
        foundAt: .now
    )
}
#endif
