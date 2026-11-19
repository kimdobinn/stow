#if DEBUG
import AppKit

/// `Stow --playback-demo` (Debug builds only): plays the two newest known videos fullscreen,
/// muted, in the alarm window, and prints the player's events. Stops by itself after 25 s.
/// Changes nothing on disk.
@MainActor
enum PlaybackDemo {
    static let argument = "--playback-demo"

    static func run() async -> Bool {
        guard let state = try? Store(directory: AppPaths.supportDirectory).loadState() else { return false }
        let known: [Video] = state.inbox.map(\.video) + state.recentVideos.values.flatMap { $0 }
        var seen = Set<String>()
        let playable = known.filter { $0.liveStatus != .live && $0.liveStatus != .upcoming && seen.insert($0.id).inserted }
        let videos = playable.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        guard videos.count >= 2 else {
            print("Need at least two known videos.")
            return false
        }
        let player = MPVPlayer(extraArguments: ["--ao=null"], showsControls: true)
        do {
            let events = try await player.play(playlist: videos.prefix(2).map { PlayableVideo(video: $0, duration: nil) },
                                               outputDeviceUID: nil, cookiesFile: AppPaths.cookiesFile)
            let timeout = Task {
                try await Task.sleep(for: .seconds(25))
                print("demo: stopping after 25 s")
                await player.stop()
            }
            for await event in events { print(event) }
            timeout.cancel()
            return true
        } catch {
            print("Couldn't play: \(error)")
            return false
        }
    }
}
#endif
