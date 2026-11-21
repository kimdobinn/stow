import AppKit

extension AppModel {
    /// Plays `video` in Stow's player window; falls back to YouTube in the browser when it can't.
    /// Not while the alarm runs: the alarm owns the player then.
    func watch(_ video: Video) {
        guard !isAlarmRunning else {
            logAlarm(.info, "“\(video.title)” wasn't opened: the alarm is playing.")
            return
        }
        Task {
            do {
                try await WatchPlayer.shared.play(video, cookiesFile: playbackCookiesFile) { [weak self] outcome in
                    switch outcome {
                    case .watched(let videoId):
                        self?.setWatched(true, videoId: videoId)
                    case .failed(_, let message):
                        self?.logAlarm(.warning, "Couldn't play “\(video.title)” in Stow (\(message)); opened it on YouTube.")
                        Task { await WatchPlayer.shared.stop() }
                        NSWorkspace.shared.open(video.watchURL)
                    }
                }
            } catch {
                logAlarm(.warning, "Couldn't start the player for “\(video.title)”: \(error.logDescription) Opened it on YouTube.")
                NSWorkspace.shared.open(video.watchURL)
            }
        }
    }

    /// Looks `video` up ahead (the pointer is resting on it), so playing it starts at once.
    func prefetchStream(_ video: Video) {
        guard video.liveStatus != .live, video.liveStatus != .upcoming else { return }
        StreamPrefetcher.shared.prefetch(videoId: video.id, cookiesFile: playbackCookiesFile)
    }
}
