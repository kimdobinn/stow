import Foundation

// Alarm services that do nothing, for unit tests, previews, --snapshot and the self-test.

extension AlarmServices {
    /// No devices; playing anything throws.
    static var inert: AlarmServices { make(outputs: [], devices: []) }

    #if DEBUG
    /// A connected JBL plus the monitor and built-in speakers, for previews and --snapshot.
    static var sample: AlarmServices {
        make(outputs: [
            AudioOutput(uid: "40-C1-F6-88-8F-AF:output", name: "JBL Go 3", transport: .bluetooth, isDefault: false),
            AudioOutput(uid: "CRG-sample:output", name: "CRG", transport: .bluetooth, isDefault: true),
            AudioOutput(uid: "DisplayPort-sample", name: "Mi monitor", transport: .displayPort, isDefault: false),
            AudioOutput(uid: "BuiltInSpeakerDevice", name: "Mac mini Speakers", transport: .builtIn, isDefault: false),
        ], devices: [
            BluetoothAudioDevice(address: "40:C1:F6:88:8F:AF", name: "JBL Go 3", isConnected: true),
            BluetoothAudioDevice(address: "00:11:22:33:44:55", name: "CRG", isConnected: true),
        ])
    }
    #endif

    private static func make(outputs: [AudioOutput], devices: [BluetoothAudioDevice]) -> AlarmServices {
        AlarmServices(player: InertPlayer(), sound: InertSound(), outputs: InertOutputs(list: outputs),
                      speaker: InertSpeaker(devices: devices), keepAlive: InertKeepAlive(), power: InertPower(),
                      videoDetails: InertVideoDetails())
    }
}

private struct InertPlayer: AlarmPlayer {
    func play(playlist: [PlayableVideo], outputDeviceUID: String?, cookiesFile: URL?) async throws -> AsyncStream<PlayerEvent> {
        throw StowError.player("No player in this build.")
    }
    func stop() async {}
}

@MainActor
private final class InertSound: AlarmSoundPlayer {
    var isPlaying: Bool { false }
    func play(deviceUID: String?, duration: Duration) async throws { throw StowError.audio("No alarm sound in this build.") }
    func stop() {}
}

private struct InertOutputs: AudioOutputService {
    let list: [AudioOutput]
    func outputs() -> [AudioOutput] { list }
    func volume(deviceUID: String) -> Double? { nil }
    func setVolume(_ volume: Double, deviceUID: String) throws {}
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@MainActor
private final class InertSpeaker: SpeakerService {
    let devices: [BluetoothAudioDevice]
    init(devices: [BluetoothAudioDevice]) { self.devices = devices }
    func pairedAudioDevices() -> [BluetoothAudioDevice] { devices }
    func isConnected(address: String) -> Bool {
        devices.contains { AudioOutput.normalizedAddress($0.address) == AudioOutput.normalizedAddress(address) && $0.isConnected }
    }
    func connect(address: String, timeout: Duration) async -> Bool { isConnected(address: address) }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@MainActor
private final class InertKeepAlive: KeepAliveService {
    var isRunning: Bool { false }
    var deviceUID: String? { nil }
    func start(deviceUID: String, levelDBFS: Double) throws {}
    func stop() {}
    func test(deviceUID: String, levelDBFS: Double, duration: Duration) async throws {}
}

@MainActor
private final class InertPower: PowerService {
    var isHoldingSystemAwake: Bool { false }
    func holdSystemAwake(_ on: Bool) {}
    func wakeDisplay() {}
}

private struct InertVideoDetails: VideoDetailsService {
    func details(for ids: [String], cookiesFile: URL?) async -> [String: VideoDetails] { [:] }
}
