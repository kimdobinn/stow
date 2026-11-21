import Foundation
import Synchronization
@testable import Stow

// Fakes for the alarm engine's services and host. Nothing here touches devices or plays sound.

let alarmJBL = AudioOutput(uid: "40-C1-F6-88-8F-AF:output", name: "JBL Go 3", transport: .bluetooth, isDefault: false)
let alarmCRG = AudioOutput(uid: "CRG:output", name: "CRG", transport: .bluetooth, isDefault: true)
let alarmMonitor = AudioOutput(uid: "DP-1", name: "Mi monitor", transport: .displayPort, isDefault: false)
let alarmBuiltIn = AudioOutput(uid: "BuiltInSpeakerDevice", name: "Mac mini Speakers", transport: .builtIn, isDefault: false)

func alarmChannel(_ id: String = "UCtest", morning: Bool = true) -> Channel {
    Channel(info: ChannelInfo(id: id, title: id), morning: morning)
}

@MainActor
final class FakeAlarmHost: AlarmHost {
    var settings: AppSettings
    var currentState: AppState
    var playbackCookiesFile: URL?
    var runs: [AlarmRunRecord] = []
    var watched: [String] = []
    var logs: [String] = []
    var problems: [String] = []
    var pushes: [[String: String]] = []
    var refreshes = 0

    init(alarm: AlarmSettings = .default, channels: [Channel] = [alarmChannel()], state: AppState = .empty) {
        settings = AppSettings(schemaVersion: 1, channels: channels, checkIntervalMinutes: 30, launchAtLogin: false, alarm: alarm)
        currentState = state
    }

    func currentSettings() -> AppSettings { settings }
    func refreshForAlarm() async { refreshes += 1 }

    func recordAlarmRun(_ run: AlarmRunRecord, watchedIds: [String]) {
        runs.append(run)
        watched = watchedIds
        currentState.lastAlarmRun = run
        if run.trigger == .scheduled { currentState.lastScheduledAlarm = run.scheduledFor }
    }

    func logAlarm(_ level: LogLevel, _ message: String) { logs.append("\(level.rawValue): \(message)") }
    func notifyAlarmProblem(title: String, body: String) { problems.append(title) }
    func pushToPhones(_ data: [String: String]) { pushes.append(data) }
}

final class FakeAlarmPlayer: AlarmPlayer {
    /// Events sent right after `play`; without `.exited` the stream stays open until `stop()`.
    let script = Mutex<[PlayerEvent]>([])
    let failure = Mutex<StowError?>(nil)
    let plays = Mutex<[(ids: [String], output: String?)]>([])
    /// What `nowPlaying()` reports.
    let current = Mutex<NowPlaying?>(nil)
    let actions = Mutex<[PlaybackAction]>([])
    private let continuation = Mutex<AsyncStream<PlayerEvent>.Continuation?>(nil)

    func play(playlist: [PlayableVideo], outputDeviceUID: String?, cookiesFile: URL?) async throws -> AsyncStream<PlayerEvent> {
        if let failure = failure.withLock({ $0 }) { throw failure }
        plays.withLock { $0.append((playlist.map(\.video.id), outputDeviceUID)) }
        let (stream, continuation) = AsyncStream.makeStream(of: PlayerEvent.self)
        for event in script.withLock({ $0 }) {
            continuation.yield(event)
            if case .exited = event { continuation.finish() }
        }
        self.continuation.withLock { $0 = continuation }
        return stream
    }

    func stop() async {
        guard let continuation = continuation.withLock({ $0 }) else { return }
        continuation.yield(.exited(.stopped))
        continuation.finish()
    }

    func nowPlaying() async -> NowPlaying? { current.withLock { $0 } }
    func perform(_ action: PlaybackAction) async { actions.withLock { $0.append(action) } }
}

/// Records the phases the controller reports.
@MainActor
final class FakeAlarmRemote: AlarmRemoteService {
    var phases: [AlarmPhase] = []
    func alarmPhaseChanged(_ phase: AlarmPhase, run: any AlarmRunControl) { phases.append(phase) }
}

@MainActor
final class FakeAlarmSound: AlarmSoundPlayer {
    var isPlaying = false
    /// Devices it fails on ("" = the system default).
    var failingDevices: Set<String> = []
    var plays: [String?] = []

    func play(deviceUID: String?, duration: Duration) async throws {
        plays.append(deviceUID)
        if failingDevices.contains(deviceUID ?? "") { throw StowError.audio("broken") }
    }

    func stop() {}
}

final class FakeAlarmOutputs: AudioOutputService {
    let list: Mutex<[AudioOutput]>
    let volumes = Mutex<[String: Double]>([:])

    init(_ outputs: [AudioOutput]) { list = Mutex(outputs) }

    func outputs() -> [AudioOutput] { list.withLock { $0 } }
    func volume(deviceUID: String) -> Double? { volumes.withLock { $0[deviceUID] } }
    func setVolume(_ volume: Double, deviceUID: String) throws { volumes.withLock { $0[deviceUID] = volume } }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@MainActor
final class FakeAlarmSpeaker: SpeakerService {
    let outputs: FakeAlarmOutputs
    /// What a successful connect adds to the outputs; nil = connecting fails.
    var connectAdds: AudioOutput?
    var connects = 0

    init(outputs: FakeAlarmOutputs) { self.outputs = outputs }

    func pairedAudioDevices() -> [BluetoothAudioDevice] {
        [BluetoothAudioDevice(address: "40:C1:F6:88:8F:AF", name: "JBL Go 3", isConnected: isConnected(address: ""))]
    }
    func isConnected(address: String) -> Bool { outputs.outputs().contains(alarmJBL) }
    func connect(address: String, timeout: Duration) async -> Bool {
        connects += 1
        guard let output = connectAdds else { return false }
        outputs.list.withLock { $0.append(output) }
        return true
    }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@MainActor
final class FakeAlarmKeepAlive: KeepAliveService {
    var isRunning = false
    var deviceUID: String?
    var starts: [(String, Double)] = []

    func start(deviceUID: String, levelDBFS: Double) throws {
        isRunning = true
        self.deviceUID = deviceUID
        starts.append((deviceUID, levelDBFS))
    }
    func stop() {
        isRunning = false
        deviceUID = nil
    }
    func test(deviceUID: String, levelDBFS: Double, duration: Duration) async throws {}
}

@MainActor
final class FakeAlarmPower: PowerService {
    var isHoldingSystemAwake = false
    var displayWakes = 0
    func holdSystemAwake(_ on: Bool) { isHoldingSystemAwake = on }
    func wakeDisplay() { displayWakes += 1 }
}

final class FakeAlarmDetails: VideoDetailsService {
    /// Missing ids are playable and 10 minutes long.
    let known = Mutex<[String: VideoDetails]>([:])
    let requested = Mutex<[[String]]>([])

    func details(for ids: [String], cookiesFile: URL?) async -> [String: VideoDetails] {
        requested.withLock { $0.append(ids) }
        let known = known.withLock { $0 }
        return Dictionary(uniqueKeysWithValues: ids.map {
            ($0, known[$0] ?? VideoDetails(id: $0, duration: 600, liveStatus: .none, isPlayable: true, error: nil))
        })
    }
}

@MainActor
struct FakeAlarmServices {
    let player = FakeAlarmPlayer()
    let sound = FakeAlarmSound()
    let outputs: FakeAlarmOutputs
    let speaker: FakeAlarmSpeaker
    let keepAlive = FakeAlarmKeepAlive()
    let power = FakeAlarmPower()
    let details = FakeAlarmDetails()
    let remote = FakeAlarmRemote()

    init(outputs: [AudioOutput] = [alarmJBL, alarmCRG, alarmMonitor, alarmBuiltIn]) {
        self.outputs = FakeAlarmOutputs(outputs)
        speaker = FakeAlarmSpeaker(outputs: self.outputs)
    }

    var services: AlarmServices {
        AlarmServices(player: player, sound: sound, outputs: outputs, speaker: speaker, keepAlive: keepAlive,
                      power: power, videoDetails: details, remote: remote)
    }
}
