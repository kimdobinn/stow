#if DEBUG
import CryptoKit
import Foundation
import Synchronization

/// `Stow --remote-demo [--remote-key <base64url>]` (Debug builds only): a test alarm on the two
/// newest known public videos, run by the real alarm engine with the phone remote on port 48261
/// (Bonjour included), but headless and silent: mpv has no window and no sound, the volume goes
/// to an in-memory output, nothing is pushed to the phones and nothing is saved (no cookies, so
/// no cookie copies either). Prints every phase, request, action and push. Ends on the phone's
/// "stop", when the videos finish, or after 10 minutes. The key is the pairing key (read, never
/// created) unless `--remote-key` gives a 32-byte one.
@MainActor
enum RemoteDemo {
    static let argument = "--remote-demo"
    static let keyArgument = "--remote-key"
    static let limit: Duration = .seconds(10 * 60)

    static func run() async -> Bool {
        guard let key = demoKey() else { return false }
        guard let state = try? Store(directory: AppPaths.supportDirectory).loadState() else {
            print("Couldn't read state.json.")
            return false
        }
        var seen = Set<String>()
        let known = state.inbox.map(\.video) + state.recentVideos.values.flatMap { $0 }
        let videos = known
            .filter { !$0.isMembersOnly && $0.liveStatus != .live && $0.liveStatus != .upcoming && seen.insert($0.id).inserted }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .prefix(2)
        guard videos.count == 2 else {
            print("Need at least two known public videos.")
            return false
        }

        let remote = AlarmRemote(loadKey: { key })
        remote.trace = { print("remote: \($0)") }
        var services = AlarmServices.inert
        services.player = MPVPlayer(extraArguments: ["--ao=null"], showsControls: false)
        services.outputs = DemoOutputs()
        services.videoDetails = DemoVideoDetails()
        services.remote = TracingRemote(remote: remote)
        let host = DemoHost(videos: Array(videos), state: state)
        let controller = AlarmController(services: services)
        controller.host = host
        print("Remote demo on \(remote.macName): \(videos.map { "“\($0.title)” (\($0.id))" }.joined(separator: ", "))")

        controller.testNow()
        let deadline = ContinuousClock.now + limit
        var stopped = false
        while controller.phase.isActive {
            if !stopped, ContinuousClock.now >= deadline {
                print("demo: stopping after \(limit)")
                stopped = true
                controller.stop()
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // The answer to the phone's "stop" may still be on its way.
        try? await Task.sleep(for: .seconds(RemoteServer.stopGrace))
        return host.lastRun?.outcome == .played
    }

    private static func demoKey() -> SymmetricKey? {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: keyArgument) {
            guard arguments.indices.contains(flag + 1), let data = Data(base64URLEncoded: arguments[flag + 1]),
                  data.count == 32 else {
                print("\(keyArgument) needs a 32-byte key in base64url.")
                return nil
            }
            print("Key: from \(keyArgument)")
            return SymmetricKey(data: data)
        }
        guard let key = PairingKey.load(at: AppPaths.pairingKeyFile) else {
            print("No pairing key at \(AppPaths.pairingKeyFile.path); pair a phone or pass \(keyArgument).")
            return nil
        }
        print("Key: the pairing key")
        return key.key
    }
}

/// Prints each phase before the real remote sees it.
@MainActor
private final class TracingRemote: AlarmRemoteService {
    let remote: AlarmRemote
    init(remote: AlarmRemote) { self.remote = remote }

    func alarmPhaseChanged(_ phase: AlarmPhase, run: any AlarmRunControl) {
        print("phase: \(phase)")
        remote.alarmPhaseChanged(phase, run: run)
    }
}

/// An alarm whose Inbox is the two demo videos (the rest of the real state stays, so the phone
/// can pick other videos); prints instead of saving, logging, notifying or pushing.
@MainActor
private final class DemoHost: AlarmHost {
    let settings: AppSettings
    let currentState: AppState
    private(set) var lastRun: AlarmRunRecord?

    init(videos: [Video], state: AppState) {
        var alarm = AlarmSettings.default
        alarm.maxVideos = videos.count
        alarm.order = .newestFirst
        alarm.volume = 40
        alarm.maxDurationMinutes = AlarmSettings.maxDurationRange.upperBound
        alarm.fallbackRules = []
        alarm.speaker = SpeakerSettings(name: "No speaker", address: nil, keepAlive: false, keepAliveLevel: -60)
        alarm.fallbackOutput = DemoOutputs.output.name
        var seen = Set<String>()
        let channels = videos.filter { seen.insert($0.channelId).inserted }
            .map { Channel(info: ChannelInfo(id: $0.channelId, title: $0.channelTitle), morning: true) }
        settings = AppSettings(schemaVersion: 1, channels: channels, checkIntervalMinutes: 30, launchAtLogin: false, alarm: alarm)
        var state = state
        state.inbox = videos.map { InboxItem(video: $0, foundAt: .now) }
        state.alarmPlayedIds = []
        state.watchedIds = []
        currentState = state
    }

    func currentSettings() -> AppSettings { settings }
    var playbackCookiesFile: URL? { nil }
    func refreshForAlarm() async {}

    func recordAlarmRun(_ run: AlarmRunRecord, watchedIds: [String]) {
        lastRun = run
        print("record: \(run.outcome.rawValue), videos \(run.videoIds), watched \(watchedIds) (not saved)")
    }

    func logAlarm(_ level: LogLevel, _ message: String) { print("log \(level.rawValue): \(message)") }
    func notifyAlarmProblem(title: String, body: String) { print("notification: \(title): \(body) (not shown)") }
    func pushToPhones(_ data: [String: String]) { print("push not sent (demo)") }
}

/// One output whose volume lives in memory.
private final class DemoOutputs: AudioOutputService {
    static let output = AudioOutput(uid: "stow-remote-demo", name: "Remote demo output", transport: .virtual, isDefault: true)
    private let level = Mutex(0.5)

    func outputs() -> [AudioOutput] { [Self.output] }
    func volume(deviceUID: String) -> Double? { level.withLock { $0 } }
    func setVolume(_ volume: Double, deviceUID: String) throws {
        level.withLock { $0 = volume }
        print("output: volume \(Int((volume * 100).rounded()))% (in memory)")
    }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

/// Every video is playable; mpv finds out otherwise.
private struct DemoVideoDetails: VideoDetailsService {
    func details(for ids: [String], cookiesFile: URL?) async -> [String: VideoDetails] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, VideoDetails(id: $0, duration: nil, liveStatus: .none, isPlayable: true, error: nil)) })
    }
}
#endif
