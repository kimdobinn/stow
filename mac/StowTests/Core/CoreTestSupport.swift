import Foundation
import Synchronization
@testable import Stow

func video(_ id: String, channel: String = "UCtest", minutesAgo: Double? = nil, live: LiveStatus = .unknown, members: Bool = false) -> Video {
    Video(id: id, channelId: channel, channelTitle: "Feed title", title: "Video \(id)",
          publishedAt: minutesAgo.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * 60) },
          thumbnailURL: nil, isMembersOnly: members, liveStatus: live)
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "StowCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

final class FakeYouTube: YouTubeService {
    let channels = Mutex<[String: ChannelInfo]>([:])
    let publicFeeds = Mutex<[String: [Video]]>([:])
    let membersFeeds = Mutex<[String: Result<MembersFeed, StowError>]>([:])

    func resolveChannel(input: String) async throws -> ChannelInfo {
        guard let info = channels.withLock({ $0[input] }) else { throw StowError.channelNotFound(input) }
        return info
    }

    func fetchPublicVideos(channelId: String) async throws -> [Video] {
        guard let videos = publicFeeds.withLock({ $0[channelId] }) else { throw StowError.network("offline") }
        return videos
    }

    let membersFetches = Mutex<[String]>([])

    func fetchMembersVideos(channelId: String, cookiesFile: URL) async throws -> MembersFeed {
        membersFetches.withLock { $0.append(channelId) }
        return try (membersFeeds.withLock { $0[channelId] } ?? .success(MembersFeed(videos: []))).get()
    }

    let streamFeeds = Mutex<[String: [Video]]>([:])
    let membersStreamFeeds = Mutex<[String: [Video]]>([:])

    func fetchPastStreams(channelId: String) async throws -> [Video] {
        streamFeeds.withLock { $0[channelId] } ?? []
    }

    func fetchMembersStreams(channelId: String, cookiesFile: URL) async throws -> MembersFeed {
        MembersFeed(videos: membersStreamFeeds.withLock { $0[channelId] } ?? [])
    }

    /// Most recently watched first.
    let history = Mutex<Result<[String], StowError>>(.success([]))
    /// Videos `markWatched` was called for, in order. A successful call also tops `history`.
    let markedWatched = Mutex<[String]>([])
    let markWatchedError = Mutex<StowError?>(nil)

    func fetchWatchHistory(cookiesFile: URL, limit: Int) async throws -> WatchHistory {
        WatchHistory(videoIds: Array(try history.withLock { $0 }.get().prefix(limit)))
    }

    let accountFeeds = Mutex<Result<AccountFeeds, StowError>>(.success(AccountFeeds(recommended: [], subscriptions: [])))
    let accountFeedFetches = Mutex(0)

    func fetchAccountFeeds(cookiesFile: URL, limit: Int) async throws -> AccountFeeds {
        accountFeedFetches.withLock { $0 += 1 }
        return try accountFeeds.withLock { $0 }.get()
    }

    /// Members-only videos the account's level can't watch ("" for "join this channel"); anything
    /// else is watchable, or public now when listed in `publicNow`.
    let lockedVideos = Mutex<[String: String]>([:])
    let publicNow = Mutex<Set<String>>([])
    let accessChecks = Mutex<[String]>([])

    func memberAccess(videoId: String, cookiesFile: URL) async throws -> MemberAccess {
        accessChecks.withLock { $0.append(videoId) }
        if publicNow.withLock({ $0.contains(videoId) }) { return .nowPublic }
        return lockedVideos.withLock { $0[videoId] }.map { .locked(level: $0.isEmpty ? nil : $0) } ?? .watchable
    }

    func markWatched(videoId: String, cookiesFile: URL) async throws {
        if let error = markWatchedError.withLock({ $0 }) { throw error }
        markedWatched.withLock { $0.append(videoId) }
        history.withLock { history in
            if case .success(let ids) = history { history = .success([videoId] + ids.filter { $0 != videoId }) }
        }
    }
}

@MainActor
final class FakeAccount: AccountService {
    var state: SignInState = .signedOut

    func refresh() async -> SignInState { state }
    var signInSucceeds = true

    func signIn() async -> Bool {
        if signInSucceeds { state = .signedIn }
        return signInSucceeds
    }
    func signOut() async { state = .signedOut }
    func fetchSubscriptions() async throws -> [ChannelInfo] {
        guard state == .signedIn else { throw StowError.notSignedIn }
        return []
    }
}

@MainActor
final class FakeNotifier: UserNotifying {
    var newVideoBatches: [[Video]] = []
    var problems: [String] = []

    func requestAuthorization() async -> Bool { true }
    func notifyNewVideos(_ videos: [Video]) { if !videos.isEmpty { newVideoBatches.append(videos) } }
    func notifyProblem(title: String, body: String) { problems.append(title) }
}
