import Foundation

/// `Stow --alarm-dryrun`: the whole alarm, headless and harmless. It plans from a temporary copy
/// of the real settings and state, runs prep for real (feed check, yt-dlp video details), lists
/// the audio outputs and the one the alarm would use, then streams the playlist through the real
/// mpv with no window and no audio for about 20 s, and prints the run record it would save.
/// It never changes a volume, the display, Bluetooth or the real files.
@MainActor
enum AlarmDryRun {
    static let argument = "--alarm-dryrun"
    static let playSeconds = 20

    static func run() async -> Bool {
        let started = ContinuousClock.now
        let log: @Sendable (String) -> Void = { message in
            let elapsed = (ContinuousClock.now - started).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            print(String(format: "[%6.1fs] ", seconds) + message)
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "stow-alarm-dryrun-\(UUID().uuidString)")
        defer {
            MPVPlayer.terminateAll()
            try? FileManager.default.removeItem(at: scratch)
        }

        print("Stow alarm dry run, \(Date.now.formatted(.iso8601))")
        print("Temporary copy: \(scratch.path)")
        let model: AppModel
        do {
            model = try makeModel(in: scratch)
        } catch {
            print("FAIL couldn't copy the settings and state: \(error.logDescription)")
            return false
        }
        printSettings(model)
        printPlan(model)
        printDevices(model.alarmSettings)

        print("\nRun (trigger test; prep, then play for about \(playSeconds) s)")
        let host = DryRunHost(model: model, log: log)
        // Each video plays at most half the time, so the move to the next entry shows up too.
        let player = MPVPlayer(extraArguments: ["--vo=null", "--ao=null",
                                                "--length=\(playSeconds / 2)"])
        let runner = AlarmRunner(trigger: .test, scheduledFor: .now, services: .dryRun(player: player, log: log),
                                 host: host) { [host] phase in host.phaseChanged(phase) }
        host.runner = runner
        await runner.run()
        host.stopTimer?.cancel()

        guard let record = host.records.last else {
            print("\nFAIL the run recorded nothing")
            return false
        }
        print("\nAlarmRunRecord it would write to state.json \"lastAlarmRun\":")
        if let data = try? Store.encoder().encode(record) { print(String(decoding: data, as: UTF8.self)) }
        print("watchedIds it would add: \(host.watched)")
        print("alarmPlayedIds a scheduled run would add (and remove from the Inbox): \(record.videoIds)")
        print("alarmPlayedIds this test run adds (only videos watched to the end): \(host.watched)")
        let ok = record.outcome == .played
        print("\nAlarm dry run \(ok ? "PASSED" : "FAILED (outcome \(record.outcome.rawValue))")")
        return ok
    }

    /// An AppModel over a copy of settings.json, state.json and cookies.txt, so prep's feed check,
    /// yt-dlp and mpv only ever write (cookie copies included) inside `directory`.
    private static func makeModel(in directory: URL) throws -> AppModel {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in [AppPaths.settingsFile, AppPaths.stateFile, AppPaths.cookiesFile]
        where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.copyItem(at: file, to: directory.appending(path: file.lastPathComponent))
        }
        let cookies = directory.appending(path: AppPaths.cookiesFile.lastPathComponent)
        let signedIn = FileManager.default.fileExists(atPath: cookies.path)
        let model = AppModel(youtube: YouTubeClient(), account: FixedAccount(state: signedIn ? .signedIn : .signedOut),
                             store: Store(directory: directory), notifier: SilentNotifier(), cookiesFile: cookies)
        model.load()
        print("Sign-in: \(signedIn ? "using a private copy of cookies.txt" : "no cookies.txt; members-only videos won't play")")
        return model
    }

    private static func printSettings(_ model: AppModel) {
        let alarm = model.alarmSettings
        print("\nSettings: alarm \(alarm.enabled ? "on" : "off") at \(alarm.time.string) on \(alarm.days.map(\.rawValue).joined(separator: " ")),"
              + " max \(alarm.maxVideos) videos (\(alarm.order.rawValue), ≤ \(alarm.maxDurationMinutes) min), volume \(alarm.volume)%")
        let next = AlarmSchedule.nextFire(after: .now, handled: model.currentState.lastScheduledAlarm, settings: alarm, calendar: .current)
        print("Next scheduled alarm: \(next?.formatted(date: .complete, time: .shortened) ?? "none")")
        print("Morning channels: \(model.channels.filter(\.morning).map(\.title).joined(separator: ", "))")
    }

    /// The planner on the copied state, before prep refreshes the feeds (the Up next preview).
    private static func printPlan(_ model: AppModel) {
        let settings = model.currentSettings()
        var generator = SeededGenerator(day: .now, calendar: .current)
        let rounds = AlarmPlanner.rounds(settings: settings.alarm, channels: settings.channels, state: model.currentState,
                                         now: .now, using: &generator)
        print("\nPlan from the saved state (before prep):")
        for round in rounds {
            let name = round.rule.map { "rule \(AlarmRunner.describe($0))" } ?? "Inbox"
            print("  \(name): \(round.candidates.count) candidates")
        }
        let preview = model.upNextPreview
        print("  Up next" + (preview.fallbackRule.map { " (fallback \(AlarmRunner.describe($0)))" } ?? "") + ":")
        for video in preview.videos { print("    \(video.id) “\(video.title)” (\(video.channelTitle))") }
        if preview.videos.isEmpty { print("    nothing: the alarm sound would play") }
    }

    private static func printDevices(_ alarm: AlarmSettings) {
        let coreAudio = CoreAudioOutputs()
        let outputs = coreAudio.outputs()
        print("\nAudio outputs:")
        for output in outputs {
            let volume = coreAudio.volume(deviceUID: output.uid).map { "\(Int(($0 * 100).rounded()))%" } ?? "no volume control"
            print("  \(output.name) [\(output.transport.rawValue)]\(output.isDefault ? " (default)" : "") uid \(output.uid), \(volume)")
        }
        print("Paired Bluetooth audio devices:")
        if DryRunBluetooth.isAuthorized {
            let devices = BluetoothSpeaker().pairedAudioDevices()
            for device in devices { print("  \(device.name) \(device.address) \(device.isConnected ? "connected" : "not connected")") }
            if devices.isEmpty { print("  none") }
        } else {
            print("  not listed: this process has no Bluetooth permission (it is granted to Stow.app when opened normally)")
        }
        let speakerOutput = AudioOutput.matching(alarm.speaker, in: outputs)
        print("Speaker \(alarm.speaker.name): " + (speakerOutput.map { "output available (\($0.uid))" }
            ?? (alarm.speaker.address == nil ? "output missing" : "output missing; prep would try to connect it first")))
        let chosen = AlarmRunner.preferredOutput(for: alarm, in: outputs)
        print("Output the alarm would use now: \(chosen.map { "\($0.name) (\($0.uid))" } ?? "the system default")")
    }

    static func describe(_ phase: AlarmPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .preparing: "preparing"
        case .starting(let output): "starting on \(output ?? "the system default")"
        case .playing(let index, let count, let video): "playing \(index + 1)/\(count) “\(video.title)”"
        case .alarmSound(let reason): "alarm sound (\(reason))"
        }
    }
}

/// Forwards to the AppModel over the temporary copy, printing logs and records as they happen.
@MainActor
private final class DryRunHost: AlarmHost {
    let model: AppModel
    let log: @Sendable (String) -> Void
    var records: [AlarmRunRecord] = []
    var watched: [String] = []
    weak var runner: AlarmRunner?
    /// Stops the run like the Stop button: `playSeconds` after the first video starts.
    var stopTimer: Task<Void, Never>?
    private var hasStarted = false

    init(model: AppModel, log: @escaping @Sendable (String) -> Void) {
        self.model = model
        self.log = log
    }

    func phaseChanged(_ phase: AlarmPhase) {
        log("phase: \(AlarmDryRun.describe(phase))")
        // The runner itself stops mpv when nothing starts in time.
        if case .playing = phase, !hasStarted {
            hasStarted = true
            stop(after: .seconds(AlarmDryRun.playSeconds),
                 reason: "\(AlarmDryRun.playSeconds) s of playback; stopping as if Stop were pressed")
        }
    }

    private func stop(after delay: Duration, reason: String) {
        stopTimer?.cancel()
        stopTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            log(reason)
            runner?.stop()
        }
    }

    func currentSettings() -> AppSettings { model.currentSettings() }
    var currentState: AppState { model.currentState }
    var playbackCookiesFile: URL? { model.playbackCookiesFile }

    func refreshForAlarm() async {
        log("feed check (trigger alarm) on the temporary copy")
        await model.refreshForAlarm()
        if let check = model.lastCheck {
            log("feed check: \(check.channelsChecked) channels, \(check.newVideos) new, \(check.errors.count) errors")
        }
    }

    func recordAlarmRun(_ run: AlarmRunRecord, watchedIds: [String]) {
        records.append(run)
        watched = watchedIds
        model.recordAlarmRun(run, watchedIds: watchedIds)
        log("record: outcome \(run.outcome.rawValue), videos \(run.videoIds)")
    }

    func logAlarm(_ level: LogLevel, _ message: String) {
        log("\(level.rawValue): \(message)")
    }

    func notifyAlarmProblem(title: String, body: String) {
        log("would notify: \(title): \(body)")
    }
}
