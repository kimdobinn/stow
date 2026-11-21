import Foundation

/// Turns mpv's IPC events into `PlayerEvent`s, SponsorBlock seeks and what the on-screen
/// controls show. Pure state machine; MPVSession performs the effects.
struct MPVPlaybackTracker {
    enum Effect: Equatable {
        case emit(PlayerEvent)
        case send(MPVCommand)
    }

    /// mpv's playlist: the initial videos, then any added with `play(_:)`. Entries are never removed,
    /// so entry id N (mpv counts from 1) is always index N − 1.
    private(set) var playlist: [PlayableVideo]
    private var segments: [String: [SponsorSegment]] = [:]
    /// Index of the entry mpv is loading or playing.
    private(set) var currentIndex: Int?
    private var currentStarted = false
    private var furthest: TimeInterval = 0
    /// The latest playback position, for the controls (`furthest` is for "watched").
    private var position: TimeInterval = 0
    /// The entry the controls show: the current one, or the next one between entries.
    private var shownIndex = 0
    /// The entry a jump asked for, shown (loading) until mpv starts it.
    private var requestedIndex: Int?
    private(set) var isPaused = false
    private var volume: Double = 100
    private var isMuted = false
    private var duration: TimeInterval?
    private var skipped: Set<Int> = []
    private var entryError: String?
    private(set) var startedCount = 0
    private var userQuit = false
    private var lastFailure: String?
    private var lastLoggedError: String?

    init(playlist: [PlayableVideo]) {
        self.playlist = playlist
    }

    mutating func setSegments(_ segments: [SponsorSegment], videoId: String) {
        self.segments[videoId] = segments
    }

    /// Jumps to entry `index` and plays it (mpv would keep a pause); nothing when there is no such entry.
    mutating func play(index: Int) -> [Effect] {
        guard playlist.indices.contains(index) else { return [] }
        requestedIndex = index
        shownIndex = index
        return [.send(.playlistPlayIndex(index)), .send(.setPause(false))]
    }

    /// Plays `video` now: jumps to it when it is in the playlist, else appends it first.
    mutating func play(_ video: PlayableVideo) -> [Effect] {
        if let index = playlist.firstIndex(where: { $0.video.id == video.video.id }) { return play(index: index) }
        playlist.append(video)
        return [.emit(.appended(video)), .send(.appendFile(video.video.watchURL))] + play(index: playlist.count - 1)
    }

    mutating func handle(_ event: MPVEvent) -> [Effect] {
        switch event {
        case .startFile(let entryId):
            beginEntry(index(of: entryId) ?? 0)
            return []
        case .playbackRestart:
            guard let index = currentIndex, !currentStarted else { return [] }
            currentStarted = true
            startedCount += 1
            let entry = playlist[index]
            return [.emit(.started(index: index, videoId: entry.video.id))]
        case .propertyChange("duration", let value):
            if let value { duration = value }
            return []
        case .propertyChange("time-pos", let value):
            guard let value, currentStarted else { return [] }
            position = value
            return progress(to: value)
        case .flagChange("pause", let value):
            isPaused = value
            return []
        case .propertyChange("volume", let value):
            if let value { volume = value }
            return []
        case .flagChange("mute", let value):
            isMuted = value
            return []
        case .endFile(let entryId, let reason, let error):
            return endEntry(index(of: entryId) ?? currentIndex, reason: reason, error: error)
        case .logMessage("error", let prefix, let text):
            let message = prefix == "ytdl_hook" && text.hasPrefix("ERROR: ") ? String(text.dropFirst(7)) : text
            if entryError == nil { entryError = message }
            lastLoggedError = message
            return []
        default:
            return []
        }
    }

    /// What the on-screen controls show; positions are whole seconds so it changes once a second.
    var nowPlaying: NowPlaying {
        let index = min(shownIndex, playlist.count - 1)
        let isPlaying = currentIndex == index && currentStarted
        return NowPlaying(index: index, count: playlist.count, video: playlist[index].video,
                          isLoading: !isPlaying, isPaused: isPaused,
                          position: isPlaying ? position.rounded(.down) : 0,
                          duration: (isPlaying ? duration : nil) ?? playlist[index].duration,
                          upNext: playlist.indices.contains(index + 1) ? playlist[index + 1].video : nil,
                          volume: volume.rounded(), isMuted: isMuted)
    }

    /// The exit to report once mpv is gone.
    func exit(stopRequested: Bool, exitCode: Int32) -> PlayerExit {
        if stopRequested || userQuit { return .stopped }
        if startedCount > 0 { return .finished }
        return .failed(lastFailure ?? lastLoggedError ?? "mpv exited (code \(exitCode)) without playing anything.")
    }

    /// mpv numbers the playlist's entries 1…N in the order they were added.
    private func index(of entryId: Int?) -> Int? {
        guard let entryId, playlist.indices.contains(entryId - 1) else { return nil }
        return entryId - 1
    }

    private mutating func beginEntry(_ index: Int) {
        currentIndex = index
        shownIndex = index
        requestedIndex = nil
        currentStarted = false
        furthest = 0
        position = 0
        duration = nil
        skipped = []
        entryError = nil
    }

    private mutating func progress(to position: TimeInterval) -> [Effect] {
        guard let index = currentIndex else { return [] }
        furthest = max(furthest, position)
        let videoId = playlist[index].video.id
        let videoSegments = segments[videoId] ?? []
        guard let skip = SponsorBlock.segmentToSkip(at: position, in: videoSegments, skipped: skipped) else { return [] }
        skipped.insert(skip)
        let segment = videoSegments[skip]
        furthest = max(furthest, segment.end)
        return [.send(.seekAbsolute(segment.end)),
                .emit(.skippedSegment(videoId: videoId, category: segment.category, from: position, to: segment.end))]
    }

    private mutating func endEntry(_ index: Int?, reason: MPVEndReason, error: String?) -> [Effect] {
        defer { currentIndex = nil }
        if reason == .quit { userQuit = true }
        guard let index else { return [] }
        shownIndex = requestedIndex ?? min(index + 1, playlist.count - 1)
        let entry = playlist[index]
        if index == currentIndex, currentStarted {
            return [.emit(.videoEnded(videoId: entry.video.id, position: furthest, duration: duration ?? entry.duration))]
        }
        guard reason == .error else { return [] }
        let message = entryError ?? error ?? "Couldn't load the video."
        lastFailure = message
        return [.emit(.loadFailed(videoId: entry.video.id, message: message))]
    }
}
