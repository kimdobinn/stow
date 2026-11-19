import Foundation

/// Turns mpv's IPC events into `PlayerEvent`s, SponsorBlock seeks and overlay banners.
/// Pure state machine; MPVSession performs the effects.
struct MPVPlaybackTracker {
    enum Effect: Equatable {
        case emit(PlayerEvent)
        case send(MPVCommand)
        case showBanner(String)
    }

    let playlist: [PlayableVideo]
    private var segments: [String: [SponsorSegment]] = [:]
    /// Index of the entry mpv is loading or playing.
    private(set) var currentIndex: Int?
    private var currentStarted = false
    private var furthest: TimeInterval = 0
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
            return [.emit(.started(index: index, videoId: entry.video.id)),
                    .showBanner(OSDOverlay.banner(index: index, count: playlist.count, video: entry.video))]
        case .propertyChange("duration", let value):
            if let value { duration = value }
            return []
        case .propertyChange("time-pos", let value):
            guard let value, currentStarted else { return [] }
            return progress(to: value)
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

    /// The exit to report once mpv is gone.
    func exit(stopRequested: Bool, exitCode: Int32) -> PlayerExit {
        if stopRequested || userQuit { return .stopped }
        if startedCount > 0 { return .finished }
        return .failed(lastFailure ?? lastLoggedError ?? "mpv exited (code \(exitCode)) without playing anything.")
    }

    /// mpv numbers the initial playlist's entries 1…N.
    private func index(of entryId: Int?) -> Int? {
        guard let entryId, playlist.indices.contains(entryId - 1) else { return nil }
        return entryId - 1
    }

    private mutating func beginEntry(_ index: Int) {
        currentIndex = index
        currentStarted = false
        furthest = 0
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
