import AVFoundation
import CoreAudio

/// Loops a system alarm sound on a specific output device (AVPlayer.audioOutputDeviceUniqueID,
/// so the system default output is left alone).
@MainActor
final class AlarmSound: AlarmSoundPlayer {
    nonisolated static let defaultSound = URL(filePath: "/System/Library/Sounds/Glass.aiff")

    private(set) var isPlaying = false
    private let sound: URL
    private let isMuted: Bool
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var finished: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?

    /// `muted` exists for tests: everything runs, nothing is heard.
    init(sound: URL = AlarmSound.defaultSound, muted: Bool = false) {
        self.sound = sound
        isMuted = muted
    }

    func play(deviceUID: String?, duration: Duration) async throws {
        stop()
        guard FileManager.default.fileExists(atPath: sound.path) else {
            throw StowError.audio("Alarm sound missing: \(sound.path)")
        }
        if let deviceUID, !Self.deviceExists(uid: deviceUID) { throw StowError.audioDeviceNotFound(deviceUID) }

        let player = AVQueuePlayer()
        player.audioOutputDeviceUniqueID = deviceUID
        player.volume = 1
        player.isMuted = isMuted
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: sound))
        self.player = player
        isPlaying = true
        player.play()

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finished = continuation
                timer = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    self?.stop()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        isPlaying = false
        finished?.resume()
        finished = nil
    }

    private static func deviceExists(uid: String) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown
    }
}
