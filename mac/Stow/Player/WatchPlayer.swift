import Foundation

/// Plays a video picked in Stow (Inbox, channel shelves) in the player window, so watching
/// doesn't need a browser. One video at a time; picking another replaces it, and the alarm
/// replaces it too (`AlarmWindow`).
@MainActor
final class WatchPlayer {
    static let shared = WatchPlayer(player: MPVPlayer(showsControls: true, mode: .watch))

    /// What happened to a video, for the app to act on.
    enum Outcome: Equatable {
        /// Watched to the end (or nearly): mark it watched.
        case watched(videoId: String)
        /// mpv couldn't play it (removed, region-locked, yt-dlp out of date…).
        case failed(videoId: String, message: String)
    }

    private let player: any AlarmPlayer
    private var listening: Task<Void, Never>?

    init(player: any AlarmPlayer) {
        self.player = player
    }

    /// Starts `video`; `onOutcome` hears when it was watched or failed. Throws when mpv can't start.
    func play(_ video: Video, cookiesFile: URL?, onOutcome: @escaping @MainActor (Outcome) -> Void) async throws {
        listening?.cancel()
        let events = try await player.play(playlist: [PlayableVideo(video: video, duration: nil)],
                                           outputDeviceUID: nil, cookiesFile: cookiesFile)
        listening = Task {
            var reported = false
            for await event in events {
                guard !reported, !Task.isCancelled else { continue }
                if let outcome = Self.outcome(of: event) {
                    reported = true
                    onOutcome(outcome)
                }
            }
        }
    }

    func stop() async {
        listening?.cancel()
        await player.stop()
    }

    static func outcome(of event: PlayerEvent) -> Outcome? {
        switch event {
        case .videoEnded(let videoId, let position, let duration):
            AlarmPlanner.isWatched(position: position, duration: duration) ? .watched(videoId: videoId) : nil
        case .loadFailed(let videoId, let message):
            .failed(videoId: videoId, message: message)
        default:
            nil
        }
    }
}
