import CoreBluetooth
import Foundation

// Alarm services for `Stow --alarm-dryrun`: the real ones where they only read, printing
// stand-ins where they would change something (volume, display, Bluetooth, sound).

extension AlarmServices {
    /// `player` is the real mpv player, made silent and windowless by the caller.
    static func dryRun(player: any AlarmPlayer, log: @escaping @Sendable (String) -> Void) -> AlarmServices {
        AlarmServices(player: DryRunPlayer(player: player, log: log), sound: DryRunSound(log: log),
                      outputs: DryRunOutputs(log: log), speaker: DryRunSpeaker(log: log), keepAlive: DryRunKeepAlive(),
                      power: DryRunPower(log: log), videoDetails: DryRunVideoDetails(log: log))
    }
}

/// IOBluetooth aborts a process whose responsible app (e.g. the terminal) has no Bluetooth
/// usage description, so devices are only listed when access was already granted.
enum DryRunBluetooth {
    static var isAuthorized: Bool { CBManager.authorization == .allowedAlways }
}

/// Prints the playlist, its SponsorBlock segments and every event of the real player.
private struct DryRunPlayer: AlarmPlayer {
    let player: any AlarmPlayer
    let log: @Sendable (String) -> Void

    func play(playlist: [PlayableVideo], outputDeviceUID: String?, cookiesFile: URL?) async throws -> AsyncStream<PlayerEvent> {
        for (index, item) in playlist.enumerated() {
            let duration = item.duration.map { Duration.seconds($0).formatted(.time(pattern: .hourMinuteSecond)) } ?? "?"
            log("playlist \(index + 1)/\(playlist.count): \(item.video.id) \(duration) “\(item.video.title)” (\(item.video.channelTitle))")
            let segments = await SponsorBlock.segments(videoId: item.video.id)
            log("  SponsorBlock: " + (segments.isEmpty ? "no segments"
                : segments.map { "\($0.category) \(Int($0.start))s–\(Int($0.end))s" }.joined(separator: ", ")))
        }
        log("mpv: starting (silent, no window), audio device \(outputDeviceUID ?? "default")")
        let events = try await player.play(playlist: playlist, outputDeviceUID: outputDeviceUID, cookiesFile: cookiesFile)
        return AsyncStream { continuation in
            let forwarding = Task {
                for await event in events {
                    log("event: \(event)")
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in forwarding.cancel() }
        }
    }

    func stop() async {
        await player.stop()
    }
}

@MainActor
private final class DryRunSound: AlarmSoundPlayer {
    let log: @Sendable (String) -> Void
    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    var isPlaying: Bool { false }
    func play(deviceUID: String?, duration: Duration) async throws {
        log("would loop the alarm sound on \(deviceUID ?? "the system default output") for \(duration) (not played)")
    }
    func stop() {}
}

private struct DryRunOutputs: AudioOutputService {
    let coreAudio = CoreAudioOutputs()
    let log: @Sendable (String) -> Void

    func outputs() -> [AudioOutput] { coreAudio.outputs() }
    func volume(deviceUID: String) -> Double? { coreAudio.volume(deviceUID: deviceUID) }
    func setVolume(_ volume: Double, deviceUID: String) throws {
        let current = coreAudio.volume(deviceUID: deviceUID).map { "\(Int(($0 * 100).rounded()))%" } ?? "no volume control"
        log("would set the volume of \(deviceUID) to \(Int((volume * 100).rounded()))% (now \(current); not changed)")
    }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@MainActor
private final class DryRunSpeaker: SpeakerService {
    let log: @Sendable (String) -> Void
    private lazy var speaker = BluetoothSpeaker()
    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    func pairedAudioDevices() -> [BluetoothAudioDevice] {
        DryRunBluetooth.isAuthorized ? speaker.pairedAudioDevices() : []
    }
    func isConnected(address: String) -> Bool {
        DryRunBluetooth.isAuthorized && speaker.isConnected(address: address)
    }
    func connect(address: String, timeout: Duration) async -> Bool {
        log("would connect \(address) (timeout \(timeout); not connected)")
        return false
    }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@MainActor
private final class DryRunKeepAlive: KeepAliveService {
    var isRunning: Bool { false }
    var deviceUID: String? { nil }
    func start(deviceUID: String, levelDBFS: Double) throws {}
    func stop() {}
    func test(deviceUID: String, levelDBFS: Double, duration: Duration) async throws {}
}

@MainActor
private final class DryRunPower: PowerService {
    let log: @Sendable (String) -> Void
    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    var isHoldingSystemAwake: Bool { false }
    func holdSystemAwake(_ on: Bool) {}
    func wakeDisplay() { log("would wake the display (not woken)") }
}

/// The real yt-dlp lookup, printing each result.
private struct DryRunVideoDetails: VideoDetailsService {
    let log: @Sendable (String) -> Void

    func details(for ids: [String], cookiesFile: URL?) async -> [String: VideoDetails] {
        log("yt-dlp -J: looking up \(ids.joined(separator: ", ")) (\(cookiesFile == nil ? "no cookies" : "private cookies copy"))")
        let found = await YTDLPVideoDetails().details(for: ids, cookiesFile: cookiesFile)
        for id in ids {
            guard let info = found[id] else { continue }
            let duration = info.duration.map { "\(Int($0))s" } ?? "?"
            log("  \(id): playable \(info.isPlayable), \(duration), live \(info.liveStatus.rawValue)"
                + (info.error.map { ", error: \($0)" } ?? ""))
        }
        return found
    }
}
