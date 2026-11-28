import StowKit

/// What you can do with a video, from its ⋯ menu, a long press or its download disc. The shell
/// makes the app's set (`Shell.actions`); a screen changes what it needs, e.g. `play` to play
/// within its own list.
struct VideoActions {
    /// Plays it: from the phone when downloaded, otherwise streamed.
    var play: (VideoItem) -> Void
    /// Downloads it (long videos ask first, with the size) or retries a failed download.
    var download: (VideoItem) -> Void
    /// Deletes the download, or stops one under way.
    var delete: (VideoItem) -> Void
    var setWatched: (VideoItem, Bool) -> Void
    var saveToPlaylist: (VideoItem) -> Void
    var openChannel: (String) -> Void
    /// A short confirmation at the bottom of the screen.
    var notify: (String) -> Void = { _ in }
    /// Shown when the list is a playlist.
    var removeFromPlaylist: ((VideoItem) -> Void)?
    var move: ((VideoItem, Int) -> Void)?
    /// Puts the video's channel in your channel groups.
    var addToGroup: ((VideoItem) -> Void)?
    /// Standalone only: follows the video's channel ("Follow <channel>" in the menu).
    var follow: ((VideoItem) -> Void)?
    /// Whether a channel is followed (the Follow item shows only when it isn't).
    var isFollowing: (String) -> Bool = { _ in false }
    /// Standalone: any video can be marked (un)watched, not only ones the Mac sent.
    var marksAnyWatched = false

    /// Does nothing (previews).
    static let none = VideoActions(play: { _ in }, download: { _ in }, delete: { _ in }, setWatched: { _, _ in },
                                   saveToPlaylist: { _ in }, openChannel: { _ in })

    /// The same, but playing with `play` (e.g. within a channel's or playlist's videos).
    func playing(_ play: @escaping (VideoItem) -> Void) -> VideoActions {
        var copy = self
        copy.play = play
        return copy
    }
}
