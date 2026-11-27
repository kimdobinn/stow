import AVFoundation
import MediaPlayer
import StowKit
import UIKit

/// The lock screen and Control Center: what's playing (title, channel, thumbnail, time) and the
/// buttons there (play and pause, previous and next in a queue, else 10 s back and forward, and
/// the scrubber).
@MainActor
final class NowPlaying {
    private weak var controller: PlaybackController?
    private var info: [String: Any] = [:]
    private var artworkTask: Task<Void, Never>?
    private var commandsReady = false

    init(controller: PlaybackController) {
        self.controller = controller
    }

    func update(_ item: VideoItem) {
        setUpCommands()
        info = [
            MPMediaItemPropertyTitle: item.video.title,
            MPMediaItemPropertyArtist: item.video.channelTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if item.durationMs > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(item.durationMs) / 1000 }
        updateTime()
        artworkTask?.cancel()
        guard let url = item.video.thumbnailURL.flatMap(URL.init(string:)) else { return }
        let id = item.id
        artworkTask = Task { [weak self] in
            guard let image = try? await ImagePipeline.shared.image(url, maxPixels: 640),
                  let self, self.controller?.currentId == id else { return }
            self.info[MPMediaItemPropertyArtwork] = Self.artwork(image)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
        }
    }

    /// Position, length and rate (after a seek, a pause or play).
    func updateTime() {
        guard let controller, controller.currentId != nil else { return }
        if controller.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = controller.duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = controller.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = controller.isPlaying ? Double(controller.player.rate) : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = controller.speed
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let commands = MPRemoteCommandCenter.shared()
        // The lock screen shows either previous and next or the skips: a queue gets previous and next.
        let queued = controller.queue.count > 1
        commands.nextTrackCommand.isEnabled = queued && controller.hasNext
        commands.previousTrackCommand.isEnabled = queued && controller.hasPrevious
        commands.skipForwardCommand.isEnabled = !queued
        commands.skipBackwardCommand.isEnabled = !queued
    }

    func clear() {
        artworkTask?.cancel()
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func setUpCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in self?.run { $0.resume() } ?? .commandFailed }
        commands.pauseCommand.addTarget { [weak self] _ in self?.run { $0.pause() } ?? .commandFailed }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.run { $0.togglePlay() } ?? .commandFailed }
        commands.nextTrackCommand.addTarget { [weak self] _ in self?.run { $0.next() } ?? .commandFailed }
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.run { $0.previous() } ?? .commandFailed }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget { [weak self] _ in self?.run { $0.seek(to: $0.position + 10) } ?? .commandFailed }
        commands.skipBackwardCommand.addTarget { [weak self] _ in self?.run { $0.seek(to: $0.position - 10) } ?? .commandFailed }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.run { $0.seek(to: event.positionTime) } ?? .commandFailed
        }
    }

    /// MediaPlayer asks for the image on its own queue, so the handler mustn't be main-actor bound.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func run(_ action: (PlaybackController) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let controller, controller.currentId != nil else { return .noActionableNowPlayingItem }
        action(controller)
        return .success
    }
}
