import Foundation

/// What the alarm's on-screen controls show.
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
}

/// What the on-screen controls ask the player to do.
enum PlaybackAction: Equatable, Sendable {
    case setPaused(Bool)
    case seekBy(TimeInterval)
    case seekTo(TimeInterval)
    case next
    /// "I'm awake": end the alarm.
    case stop
}
