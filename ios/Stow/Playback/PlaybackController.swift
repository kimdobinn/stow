import AVFoundation
import Observation
import os
import StowKit
import UIKit

/// The app's one player, shared by the watch page, the mini player, Picture in Picture and the
/// lock screen (Android's PlayerConnection and PlaybackService).
///
/// Plays a queue of video ids: a downloaded video from its file, any other streamed from YouTube
/// (yt-dlp finds the stream, which takes a few seconds). Like Android it saves where you are in
/// each video, marks it watched at 90%, counts the time watched per channel for "Your week", and
/// stops at the end of each video unless autoplay is on.
@MainActor
@Observable
final class PlaybackController {
    /// Each double-tap skips this far (taps in a row add up).
    static let skipSeconds: Double = 5
    /// How fast the video plays while you hold it.
    static let holdRate: Float = 2

    let repository: Repository
    @ObservationIgnored let player = AVPlayer()
    /// The view the video draws in; the watch page or the mini player holds it (see `VideoSurface`).
    @ObservationIgnored let videoView = PlayerVideoView()
    @ObservationIgnored private(set) lazy var pictureInPicture = PictureInPicture(controller: self)
    @ObservationIgnored private lazy var nowPlaying = NowPlaying(controller: self)

    /// Video ids in play order.
    private(set) var queue: [String] = []
    /// The video loaded (playing or paused); nil when the player is closed.
    private(set) var currentId: String?
    /// Playing, or waiting to (buffering) because you pressed play.
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    /// Looking up the stream with yt-dlp.
    private(set) var isResolving = false
    /// Why the video can't play; cleared by the next try.
    private(set) var error: String?
    /// Seconds.
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var buffered: Double = 0
    /// Stopped at the end (autoplay off, or nothing next).
    private(set) var ended = false
    /// Held down: playing at 2× until let go.
    private(set) var isHolding = false
    /// Streamed rather than played from a downloaded file.
    private(set) var isStreaming = false
    /// The downloaded file playing, for frames while scrubbing.
    private(set) var fileURL: URL?
    private(set) var isPictureInPictureActive = false

    /// Asks the app to show the watch page (Picture in Picture's "back to the app" button).
    @ObservationIgnored var onExpand: (() -> Void)?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var markedWatched: Set<String> = []
    /// Where to start once the new item can seek.
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var watchedSeconds: [String: Double] = [:]
    @ObservationIgnored private var holdResumesPlaying = false
    /// A stream that stopped working (its URL expired) is looked up again, once per video.
    @ObservationIgnored private var recoveredStream: String?
    @ObservationIgnored private let log = Logger(subsystem: "dev.stow.ios", category: "player")

    init(repository: Repository) {
        self.repository = repository
        player.defaultRate = Float(repository.prefs.playbackSpeed)
        // A video keeps playing (as sound) with the app in the background or the phone locked.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.preventsDisplaySleepDuringVideoPlayback = true
        videoView.playerLayer.player = player
        observe()
    }

    // MARK: - What's playing

    var current: VideoItem? { currentId.flatMap(repository.item) }
    private var index: Int? { currentId.flatMap { queue.firstIndex(of: $0) } }
    var hasPrevious: Bool { (index ?? 0) > 0 }
    var hasNext: Bool { index.map { $0 < queue.count - 1 } ?? false }
    var upNext: [VideoItem] {
        guard let index else { return [] }
        return queue.dropFirst(index + 1).compactMap(repository.item)
    }
    var speed: Double { repository.prefs.playbackSpeed }
    /// 0…1 of the way through.
    var fraction: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }

    // MARK: - Playing

    /// Plays `request.startId` within `request.queue`, resuming where you left off. The same video
    /// in the same queue just carries on.
    func play(_ request: PlaybackRequest) {
        if currentId == request.startId, queue == request.queue, error == nil, player.currentItem != nil || isResolving {
            if !isPlaying, !ended { resume() }
            return
        }
        queue = request.queue
        log.info("Playing \(request.startId, privacy: .public) in a queue of \(request.queue.count)")
        start(request.startId)
    }

    /// Plays another video of the queue (Up next), or one on its own.
    func jump(to id: String) {
        if !queue.contains(id) { queue = [id] }
        start(id)
    }

    func next() {
        guard let index, index < queue.count - 1 else { return }
        start(queue[index + 1])
    }

    func previous() {
        guard let index, index > 0 else { return }
        start(queue[index - 1])
    }

    /// Tries the video again after an error.
    func retry() {
        guard let currentId else { return }
        recoveredStream = nil
        start(currentId)
    }

    func togglePlay() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard currentId != nil else { return }
        if ended {
            ended = false
            seek(to: 0)
        }
        activateAudio()
        player.play()
    }

    func pause() {
        player.pause()
        savePosition()
    }

    /// Stops and closes the player.
    func stop() {
        savePosition()
        loadTask?.cancel()
        loadTask = nil
        if isHolding { endHold() }
        player.pause()
        clearItem()
        currentId = nil
        queue = []
        error = nil
        isResolving = false
        ended = false
        position = 0
        duration = 0
        buffered = 0
        fileURL = nil
        nowPlaying.clear()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func seek(to seconds: Double) {
        let target = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        position = target
        if ended, target < duration - 0.5 { ended = false }
        guard player.currentItem?.status == .readyToPlay else {
            pendingSeek = target
            return
        }
        // Exact for files (cheap); streams may land on the nearest segment boundary instead.
        let tolerance = isStreaming ? CMTime(seconds: 0.5, preferredTimescale: 600) : .zero
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in self?.nowPlaying.updateTime() }
        }
    }

    /// Double-tap: 5 s back or forward.
    func skip(forward: Bool) {
        seek(to: position + (forward ? Self.skipSeconds : -Self.skipSeconds))
    }

    func setSpeed(_ speed: Double) {
        repository.prefs.playbackSpeed = speed
        player.defaultRate = Float(speed)
        if isPlaying, !isHolding { player.rate = Float(speed) }
        nowPlaying.updateTime()
    }

    /// Held down: 2× until let go, then back as it was.
    func beginHold() {
        guard currentId != nil, !isHolding, !ended else { return }
        holdResumesPlaying = isPlaying
        isHolding = true
        log.info("Holding at 2×")
        activateAudio()
        player.rate = Self.holdRate
    }

    func endHold() {
        guard isHolding else { return }
        isHolding = false
        if holdResumesPlaying { player.rate = Float(speed) } else { player.pause() }
    }

    // MARK: - Loading

    private func start(_ id: String) {
        savePosition()
        loadTask?.cancel()
        loadTask = nil
        if isHolding { endHold() }
        currentId = id
        error = nil
        ended = false
        position = 0
        buffered = 0
        pendingSeek = nil
        guard let item = repository.item(id) else {
            clearItem()
            error = "This video isn't on the phone any more."
            return
        }
        duration = Double(item.durationMs) / 1000
        if item.isPlayable, let file = repository.fileURL(for: id) {
            isStreaming = false
            isResolving = false
            fileURL = file
            load(AVPlayerItem(asset: AVURLAsset(url: file)), from: resumePosition(item))
        } else {
            stream(item)
        }
        nowPlaying.update(item)
    }

    /// Where you left off; from the start when you'd (nearly) finished it.
    private func resumePosition(_ item: VideoItem) -> Double {
        guard let local = item.local, local.positionMs > 0 else { return 0 }
        if local.durationMs > 0, Double(local.positionMs) >= Double(local.durationMs) * 0.95 { return 0 }
        return Double(local.positionMs) / 1000
    }

    /// Looks the stream up with yt-dlp, then plays it straight from YouTube.
    private func stream(_ item: VideoItem, from start: Double? = nil) {
        let id = item.id
        isStreaming = true
        isResolving = true
        fileURL = nil
        clearItem()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await repository.stream(item.video)
                let playerItem = try await StreamItem.make(info)
                guard !Task.isCancelled, currentId == id else { return }
                isResolving = false
                load(playerItem, from: start ?? resumePosition(item))
            } catch {
                guard !Task.isCancelled, currentId == id, !(error is CancellationError) else { return }
                isResolving = false
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.error = "Couldn't stream this video. \(message)".trimmingCharacters(in: .whitespaces)
                log.warning("Stream \(id, privacy: .public) failed: \(message, privacy: .public)")
            }
        }
    }

    private func load(_ item: AVPlayerItem, from start: Double) {
        // YouTube's HLS also lists 1440p and 4K (VP9): streams are capped like downloads.
        item.preferredMaximumResolution = YtDlpStream.preferredMaximumResolution
        item.audioTimePitchAlgorithm = .timeDomain
        pendingSeek = start > 1 ? start : nil
        position = start > 1 ? start : 0
        observe(item)
        // Made now, so leaving the app can float the video (Picture in Picture starts on its own).
        _ = pictureInPicture
        player.replaceCurrentItem(with: item)
        activateAudio()
        player.play()
    }

    private func clearItem() {
        itemObservations = []
        player.replaceCurrentItem(with: nil)
    }

    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            log.warning("Audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Watching the player

    private func observe() {
        // KVO calls these on whatever thread changed the value: they hop to the main actor.
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] player, _ in
            let status = player.timeControlStatus
            let waiting = player.reasonForWaitingToPlay
            Task { @MainActor in self?.timeControlChanged(status, waiting: waiting) }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeChanged(time) }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, item == self.player.currentItem else { return }
                self.reachedEnd()
            }
        }
        center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self, let item, item == self.player.currentItem else { return }
                self.failed(error)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.tick()
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations = [
            item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
                let status = item.status
                let error = item.error
                Task { @MainActor in
                    guard let self, item == self.player.currentItem else { return }
                    if status == .readyToPlay { self.becameReady(item) }
                    if status == .failed { self.failed(error) }
                }
            },
        ]
    }

    private func becameReady(_ item: AVPlayerItem) {
        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0 { duration = seconds }
        if let pendingSeek {
            self.pendingSeek = nil
            seek(to: pendingSeek)
        }
        nowPlaying.updateTime()
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus, waiting: AVPlayer.WaitingReason?) {
        let playing = status != .paused
        isBuffering = status == .waitingToPlayAtSpecifiedRate && waiting != .noItemToPlay
        if playing != isPlaying {
            isPlaying = playing
            if !playing { savePosition() }
            nowPlaying.updateTime()
        }
    }

    private func timeChanged(_ time: CMTime) {
        guard currentId != nil, pendingSeek == nil else { return }
        let seconds = time.seconds
        if seconds.isFinite { position = max(seconds, 0) }
        if let item = player.currentItem {
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
            if let range = item.loadedTimeRanges.last?.timeRangeValue {
                buffered = (range.start + range.duration).seconds
            }
        }
    }

    private func reachedEnd() {
        guard let currentId else { return }
        position = duration
        markWatched(currentId)
        if repository.prefs.autoplay, hasNext {
            next()
        } else {
            ended = true
            savePosition()
            nowPlaying.updateTime()
        }
    }

    private func failed(_ error: Error?) {
        guard let currentId, let item = repository.item(currentId) else { return }
        let message = error?.localizedDescription ?? "Unknown error"
        log.warning("Playback of \(currentId, privacy: .public) failed: \(message, privacy: .public)")
        // YouTube's stream URLs stop working after a few hours: look it up again where it stopped.
        if isStreaming, recoveredStream != currentId {
            recoveredStream = currentId
            stream(item, from: position)
            return
        }
        clearItem()
        self.error = isStreaming ? "Couldn't stream this video. \(message)" : "Couldn't play this video. \(message)"
    }

    // MARK: - Every 2 seconds: position, time watched, watched at 90%

    private func tick() {
        let now = Date.now
        let elapsed = lastTick.map { min(now.timeIntervalSince($0), 5) } ?? 0
        lastTick = now
        guard let currentId, duration > 0 else { return }
        log.debug("\(currentId, privacy: .public) at \(self.position, format: .fixed(precision: 1)) of \(self.duration, format: .fixed(precision: 1)) s, playing \(self.isPlaying), streaming \(self.isStreaming)")
        if isPlaying, !isBuffering, elapsed > 0 { countWatchTime(currentId, seconds: elapsed) }
        if isPlaying { savePosition() }
        if position >= duration * 0.9 || ended { markWatched(currentId) }
    }

    /// Wall-clock time actually spent watching, per channel, for "Your week".
    private func countWatchTime(_ id: String, seconds: Double) {
        guard let channelId = repository.item(id)?.video.channelId, !channelId.isEmpty else { return }
        let total = (watchedSeconds[channelId] ?? 0) + seconds
        let whole = Int(total)
        watchedSeconds[channelId] = total - Double(whole)
        if whole > 0 { repository.stats.addSeconds(channelId, whole) }
    }

    private func markWatched(_ id: String) {
        guard !markedWatched.contains(id) else { return }
        markedWatched.insert(id)
        if repository.item(id)?.watched == false { repository.setWatched(id, true) }
    }

    private func savePosition() {
        guard let currentId, duration > 0 else { return }
        repository.savePosition(currentId, positionMs: Int(position * 1000), durationMs: Int(duration * 1000))
    }

    // MARK: - Picture in Picture

    func pictureInPictureChanged(_ active: Bool) {
        isPictureInPictureActive = active
    }

    func restoreFromPictureInPicture() {
        onExpand?()
    }
}
