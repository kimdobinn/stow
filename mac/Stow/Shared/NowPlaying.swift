import Foundation

/// What the alarm's on-screen controls (and the phone remote) show.
struct NowPlaying: Equatable, Sendable {
    /// 0-based playlist index of the video playing or loading.
    var index: Int
    var count: Int
    var video: Video
    /// Being fetched or buffered; nothing on screen yet.
    var isLoading: Bool
    var isPaused: Bool
    /// Whole seconds.
    var position: TimeInterval
    var duration: TimeInterval?
    var upNext: Video?
    /// mpv's own volume, 0–100 (on top of the output device's volume, which the alarm sets).
    var volume: Double = 100
    var isMuted = false
}

/// What the on-screen controls or the phone remote ask the player to do.
enum PlaybackAction: Equatable, Sendable {
    case setPaused(Bool)
    case seekBy(TimeInterval)
    case seekTo(TimeInterval)
    case next
    /// Jump to an existing playlist entry (0-based).
    case playIndex(Int)
    /// Play this video now, appending it to the playlist unless it is already in it.
    case playVideo(PlayableVideo)
    case setVolume(Double)
    case setMuted(Bool)
    /// "I'm awake": end the alarm.
    case stop
}
