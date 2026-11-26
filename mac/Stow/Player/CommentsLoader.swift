import Foundation
import Observation

/// The comments of the video being watched, fetched when the comments column opens and kept for
/// the last few videos.
@MainActor
@Observable
final class CommentsLoader {
    static let shared = CommentsLoader()

    enum State: Equatable {
        case idle
        case loading
        case loaded(CommentsPage)
        case failed(String)
    }

    private(set) var videoId: String?
    private(set) var state: State = .idle
    @ObservationIgnored private var cache: [String: CommentsPage] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var fetch: @Sendable (String, URL?) async throws -> CommentsPage = CommentsFetcher.fetch
    static let cachedVideos = 10

    init() {}

    /// Shows `videoId`'s comments, fetching them unless they're here already (or `retry` asks again).
    func load(videoId: String, cookiesFile: URL?, retry: Bool = false) {
        if videoId == self.videoId, !retry, state != .idle { return }
        task?.cancel()
        self.videoId = videoId
        if let page = cache[videoId], !retry {
            state = .loaded(page)
            return
        }
        state = .loading
        let fetch = fetch
        task = Task { [weak self] in
            let result = await Task.detached { () -> Result<CommentsPage, Error> in
                do { return .success(try await fetch(videoId, cookiesFile)) } catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, let self, self.videoId == videoId else { return }
            switch result {
            case .success(let page):
                self.remember(page, for: videoId)
                self.state = .loaded(page)
            case .failure(let error):
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    /// Waits for the fetch under way (tests).
    func settle() async { await task?.value }

    private func remember(_ page: CommentsPage, for videoId: String) {
        cache[videoId] = page
        order.removeAll { $0 == videoId }
        order.append(videoId)
        while order.count > Self.cachedVideos { cache[order.removeFirst()] = nil }
    }

    private static func message(for error: Error) -> String {
        switch error as? StowError {
        case .network: "Couldn't reach YouTube. Check the connection and try again."
        case .timedOut: "YouTube took too long to answer."
        case .toolNotFound: "yt-dlp isn't installed."
        default: "Couldn't load the comments."
        }
    }
}
