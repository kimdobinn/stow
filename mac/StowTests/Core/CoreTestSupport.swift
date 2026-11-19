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

    func fetchMembersVideos(channelId: String, cookiesFile: URL) async throws -> MembersFeed {
        try (membersFeeds.withLock { $0[channelId] } ?? .success(MembersFeed(videos: []))).get()
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
