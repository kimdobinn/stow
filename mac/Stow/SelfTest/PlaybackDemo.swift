#if DEBUG
import AppKit

/// `Stow --playback-demo` (Debug builds only): plays the two newest known videos fullscreen,
/// muted, with the alarm's controls, and prints the player's events. Changes nothing on disk.
@MainActor
enum PlaybackDemo {
    static let argument = "--playback-demo"

    static func run() async -> Bool {
        guard let state = try? Store(directory: AppPaths.supportDirectory).loadState() else { return false }
        let known: [Video] = state.inbox.map(\.video) + state.recentVideos.values.flatMap { $0 }
        let playable = known.filter { $0.liveStatus != .live && $0.liveStatus != .upcoming }
        let videos = playable.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        guard videos.count >= 2 else {
            print("Need at least two known videos.")
            return false
        }
        let player = MPVPlayer(extraArguments: ["--ao=null"], showsControls: true)
        do {
            let events = try await player.play(playlist: videos.prefix(2).map { PlayableVideo(video: $0, duration: nil) },
                                               outputDeviceUID: nil, cookiesFile: AppPaths.cookiesFile)
            for await event in events { print(event) }
            return true
        } catch {
            print("Couldn't play: \(error)")
            return false
        }
    }
}
#endif
