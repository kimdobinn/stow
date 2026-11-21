import Foundation

/// One alarm run: prep (speaker, feeds, video details), then at `scheduledFor` play the videos,
/// or the alarm sound when streaming fails, and record the outcome. The user must always wake up.
@MainActor
final class AlarmRunner {
    static let connectTimeout: Duration = .seconds(20)
    /// CoreAudio adds a Bluetooth speaker's output a moment after the link comes up.
    static let outputAppearTimeout: Duration = .seconds(10)
    /// The output the alarm wants (speaker or fallback) may come back a moment after the display wakes
    /// (a monitor's DisplayPort audio disappears while it sleeps).
    static let displayAudioTimeout: Duration = .seconds(8)
    static let refreshLimit: TimeInterval = 120
    static let planLimit: TimeInterval = 150
    /// Prep may run this far past the alarm time; then the videos play unchecked.
    static let prepGrace: TimeInterval = 20
    /// The feed refresh is skipped unless it leaves this long for the video check.
    static let planReserve: TimeInterval = 60
    /// The video check gets at least this long, even when the alarm is already due.
    static let minimumPlanTime: TimeInterval = 20
    /// Added to the longest the playlist could take before the run is cut off, so a wedged
    /// player can't block later alarms.
    static let runMargin: TimeInterval = 30 * 60
    static let alarmSoundDuration: Duration = .seconds(10 * 60)
    static let builtInSpeakers = "Mac mini Speakers"

    let trigger: AlarmTrigger
    let scheduledFor: Date
    /// Without a first video by then (stalled yt-dlp, slow network) mpv is stopped and the alarm
    /// sound rings; restarted by each video that fails to load. Settable for tests.
    var startLimit: Duration = .seconds(90)
    private(set) var isStopping = false
    /// What mpv plays, in order, including videos added from the phone; empty until it starts.
    private(set) var playlist: [PlayableVideo] = []
    /// The output the alarm plays on, once chosen.
    private(set) var output: AudioOutput?
    /// Cancelled because the alarm time changed during prep: not recorded.
    private var isAbandoned = false

    private let services: AlarmServices
    private let host: any AlarmHost
    private let onPhase: (AlarmPhase) -> Void
    private var record: AlarmRunRecord
    private var watched: [String] = []
    private var triedConnecting = false
    /// While mpv runs: when it is stopped unless a video has started.
    private var startDeadline: ContinuousClock.Instant?
    /// Why the watchdog stopped mpv.
    private var playerTimeout: String?
    /// When the run is cut off; later for every video added from the phone.
    private var runDeadline: ContinuousClock.Instant?
    /// A volume the phone chose before the output was; it replaces the configured volume.
    private var requestedVolume: Int?

    init(trigger: AlarmTrigger, scheduledFor: Date, services: AlarmServices, host: any AlarmHost,
         onPhase: @escaping (AlarmPhase) -> Void) {
        self.trigger = trigger
        self.scheduledFor = scheduledFor
        self.services = services
        self.host = host
        self.onPhase = onPhase
        record = AlarmRunRecord(trigger: trigger, scheduledFor: scheduledFor, startedAt: .now, videoIds: [], outcome: .running)
    }

    /// The speaker's output, else the fallback output, else the built-in speakers, else the system default.
    static func preferredOutput(for alarm: AlarmSettings, in outputs: [AudioOutput]) -> AudioOutput? {
        AudioOutput.matching(alarm.speaker, in: outputs)
            ?? AudioOutput.named(alarm.fallbackOutput, in: outputs)
            ?? AudioOutput.named(builtInSpeakers, in: outputs)
            ?? outputs.first { $0.transport == .builtIn }
            ?? outputs.first(where: \.isDefault)
    }

    /// Stops mpv and the alarm sound; prep notices at its next step (the controller also cancels it).
    func stop() {
        guard !isStopping else { return }
        isStopping = true
        services.sound.stop()
        let player = services.player
        Task { await player.stop() }
    }

    /// Sets the output's own volume (0–100) while it plays; before that, the volume it will get.
    func setOutputVolume(_ volume: Int) {
        let volume = min(max(volume, AlarmSettings.volumeRange.lowerBound), AlarmSettings.volumeRange.upperBound)
        guard let output else {
            requestedVolume = volume
            return
        }
        setVolume(volume, on: output)
    }

    /// The output's own volume, 0–100; before the output is chosen, the one it will get (so the
    /// phone shows a volume it can change during prep).
    var outputVolume: Int? {
        guard let output else { return requestedVolume ?? host.currentSettings().alarm.volume }
        return services.outputs.volume(deviceUID: output.uid).map { Int(($0 * 100).rounded()) }
    }

    /// Cancels a run whose alarm time no longer exists (settings changed during prep).
    func abandon() {
        isAbandoned = true
        stop()
    }

    func run() async {
        onPhase(.preparing(scheduledFor: scheduledFor))
        log(.info, "preparing (\(trigger.rawValue) alarm for \(scheduledFor.formatted(date: .abbreviated, time: .shortened))).")
        let plan = await prepare()
        if !isStopping { try? await AlarmWaiting.sleep(until: scheduledFor) }
        if isStopping || Task.isCancelled {
            return finish(.stopped, error: "Stopped before anything played.")
        }
        let settings = host.currentSettings().alarm
        // First, so a monitor's DisplayPort audio is back before the output is chosen.
        services.power.wakeDisplay()
        let output = await chooseOutput(settings)
        self.output = output
        record.output = output?.name ?? "System default"
        let previousVolume = output.flatMap { services.outputs.volume(deviceUID: $0.uid) }
        let volume = requestedVolume ?? settings.volume
        setVolume(volume, on: output)
        defer { if let previousVolume { restoreVolume(previousVolume, on: output) } }
        onPhase(.starting(output: output?.name))
        record.fallbackRule = plan.fallbackRule

        var failure: String?
        if let skip = plan.videos.isEmpty ? plan.skipped.first : nil {
            failure = "No playable video (“\(skip.video.title)”: \(skip.reason))."
        } else if plan.videos.isEmpty {
            failure = "Nothing to play: no new morning videos and no fallback rule matched."
        } else {
            log(.info, "playing \(plan.videos.count) video(s) on \(record.output ?? "?") at \(volume)%"
                + (plan.fallbackRule.map { " (fallback rule \(Self.describe($0)))" } ?? "") + ".")
            failure = await play(plan.videos, on: output, maxDurationMinutes: settings.maxDurationMinutes)
        }
        if let failure, !isStopping {
            await soundAlarm(reason: failure, on: output)
        } else if record.videoIds.isEmpty {
            finish(.stopped, error: record.error ?? "Stopped before anything played.")
        } else {
            finish(.played, error: record.error)
        }
    }

    // MARK: Prep

    /// Playing on time matters more than fresh feeds or checked videos, so both steps share the
    /// time left until shortly after the alarm (a test gets the time a scheduled run would).
    private func prepare() async -> AlarmPlanner.Plan {
        async let connecting: Void = connectSpeakerIfMissing()
        let host = host
        let lead = trigger == .test ? AlarmSchedule.prepLead : 0
        let deadline = max(scheduledFor, record.startedAt.addingTimeInterval(lead)).addingTimeInterval(Self.prepGrace)
        let refreshBudget = min(Self.refreshLimit, deadline.timeIntervalSinceNow - Self.planReserve)
        if refreshBudget > 0 {
            _ = await AlarmWaiting.value(of: Task { await host.refreshForAlarm() }, within: .seconds(refreshBudget))
        } else {
            log(.info, "skipped the feed refresh: the alarm is already due.")
        }

        let settings = host.currentSettings()
        var generator = SeededGenerator(day: scheduledFor, calendar: .current)
        let rounds = AlarmPlanner.rounds(settings: settings.alarm, channels: settings.channels,
                                         state: host.currentState, now: .now, using: &generator)
        let details = services.videoDetails
        let cookies = host.playbackCookiesFile
        let maxMinutes = settings.alarm.maxDurationMinutes
        let planning = Task {
            await AlarmPlanner.plan(rounds, maxDurationMinutes: maxMinutes) { ids in
                await details.details(for: ids, cookiesFile: cookies)
            }
        }
        let planBudget = min(Self.planLimit, max(Self.minimumPlanTime, deadline.timeIntervalSinceNow))
        let checked = await AlarmWaiting.value(of: planning, within: .seconds(planBudget))
        planning.cancel()
        await connecting

        guard let checked else {
            if !isStopping { log(.warning, "checking videos took too long; playing them unchecked.") }
            return AlarmPlanner.unchecked(rounds)
        }
        for skip in checked.skipped {
            log(.info, "skipped “\(skip.video.title)” (\(skip.video.id)): \(skip.reason).")
        }
        return checked
    }

    private func connectSpeakerIfMissing() async {
        let speaker = host.currentSettings().alarm.speaker
        guard let address = speaker.address, !triedConnecting, !isStopping,
              AudioOutput.matching(speaker, in: services.outputs.outputs()) == nil else { return }
        triedConnecting = true
        log(.info, "\(speaker.name) isn't connected; connecting.")
        guard await services.speaker.connect(address: address, timeout: Self.connectTimeout) else {
            return log(.warning, "couldn't connect \(speaker.name) (off or out of range?).")
        }
        let appeared = await AlarmWaiting.poll(within: Self.outputAppearTimeout) {
            AudioOutput.matching(speaker, in: services.outputs.outputs()) != nil
        }
        log(appeared ? .info : .warning,
            appeared ? "connected \(speaker.name)." : "connected \(speaker.name), but its audio output didn't appear.")
    }

    // MARK: Run

    private func chooseOutput(_ settings: AlarmSettings) async -> AudioOutput? {
        await connectSpeakerIfMissing()
        _ = await AlarmWaiting.poll(within: Self.displayAudioTimeout) {
            let outputs = services.outputs.outputs()
            return AudioOutput.matching(settings.speaker, in: outputs) != nil
                || AudioOutput.named(settings.fallbackOutput, in: outputs) != nil
        }
        let outputs = services.outputs.outputs()
        let chosen = Self.preferredOutput(for: settings, in: outputs)
        if AudioOutput.matching(settings.speaker, in: outputs) == nil {
            log(.warning, "\(settings.speaker.name) isn't available; using \(chosen?.name ?? "the system default output").")
        }
        return chosen
    }

    private func setVolume(_ volume: Int, on output: AudioOutput?) {
        guard let output else { return }
        do {
            try services.outputs.setVolume(Double(volume) / 100, deviceUID: output.uid)
        } catch {
            log(.warning, "couldn't set the volume of \(output.name): \(error.logDescription)")
        }
    }

    private func restoreVolume(_ volume: Double, on output: AudioOutput?) {
        guard let output else { return }
        do {
            try services.outputs.setVolume(volume, deviceUID: output.uid)
        } catch {
            log(.warning, "couldn't put the volume of \(output.name) back: \(error.logDescription)")
        }
    }

    /// Plays `playlist` until mpv exits. Returns why nothing could be played, or nil when
    /// something played or the user stopped it.
    private func play(_ videos: [PlayableVideo], on output: AudioOutput?, maxDurationMinutes: Int) async -> String? {
        let events: AsyncStream<PlayerEvent>
        do {
            events = try await services.player.play(playlist: videos, outputDeviceUID: output?.uid,
                                                    cookiesFile: host.playbackCookiesFile)
        } catch {
            return "The player couldn't start: \(error.logDescription)"
        }
        playlist = videos
        if isStopping { await services.player.stop() }
        startDeadline = .now + startLimit
        let maxDuration = Duration.seconds(maxDurationMinutes * 60)
        runDeadline = .now + maxDuration * videos.count + .seconds(Self.runMargin)
        let watchdog = Task { await watchPlayer() }
        defer { watchdog.cancel() }

        var exit = PlayerExit.failed("The player ended without reporting why.")
        var lastLoadError: String?
        for await event in events {
            switch event {
            case .started(let index, let videoId):
                guard playlist.indices.contains(index) else { continue }
                let video = playlist[index].video
                if !record.videoIds.contains(videoId) { record.videoIds.append(videoId) }
                onPhase(.playing(index: index, count: playlist.count, video: video))
                host.recordAlarmRun(record, watchedIds: watched)
                log(.info, "playing \(index + 1)/\(playlist.count) “\(video.title)” (\(video.channelTitle), \(videoId)).")
            case .videoEnded(let videoId, let position, let duration):
                let total = duration ?? playlist.first { $0.video.id == videoId }?.duration
                if AlarmPlanner.isWatched(position: position, duration: total), !watched.contains(videoId) {
                    watched.append(videoId)
                }
            case .skippedSegment(let videoId, let category, let from, let to):
                log(.info, "skipped SponsorBlock \(category) in \(videoId) (\(Int(from))s–\(Int(to))s).")
            case .loadFailed(let videoId, let message):
                lastLoadError = message
                startDeadline = .now + startLimit
                log(.warning, "couldn't load \(videoId): \(message)")
            case .appended(let added):
                playlist.append(added)
                runDeadline = runDeadline.map { $0 + maxDuration }
                log(.info, "added “\(added.video.title)” (\(added.video.channelTitle), \(added.video.id)) to the playlist.")
            case .exited(let reason):
                exit = reason
            }
        }

        if let playerTimeout {
            log(.warning, "\(playerTimeout) Stopped the player.")
            guard record.videoIds.isEmpty else {
                record.error = playerTimeout
                return nil
            }
            return playerTimeout
        }
        if case .failed(let message) = exit, !isStopping {
            log(.warning, "the player failed: \(message)")
            if !record.videoIds.isEmpty { record.error = message }
        }
        guard record.videoIds.isEmpty, !isStopping else { return nil }
        switch exit {
        case .stopped:
            record.error = "The player was closed before anything played."
            return nil
        case .finished:
            return "No video could be streamed" + (lastLoadError.map { ": \($0)" } ?? ".")
        case .failed(let message):
            return "The player failed: \(message)"
        }
    }

    /// Stops mpv when no video has started by `startDeadline`, or when the run outlasts `runDeadline`.
    private func watchPlayer() async {
        while !Task.isCancelled, !isStopping {
            let now = ContinuousClock.now
            if record.videoIds.isEmpty, let startDeadline, now >= startDeadline {
                playerTimeout = "No video started within \(startLimit)."
            } else if let runDeadline, now >= runDeadline {
                playerTimeout = "The alarm ran far longer than its videos."
            }
            if playerTimeout != nil { return await services.player.stop() }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func soundAlarm(reason: String, on output: AudioOutput?) async {
        onPhase(.alarmSound(reason: reason))
        log(.error, "\(reason) Playing the alarm sound instead.")
        host.notifyAlarmProblem(title: "The alarm couldn't play videos", body: reason)
        let devices: [String?] = output.map { [$0.uid, nil] } ?? [nil]
        for device in devices where !isStopping {
            do {
                try await services.sound.play(deviceUID: device, duration: Self.alarmSoundDuration)
                return finish(record.videoIds.isEmpty ? .alarmSound : .played, error: reason)
            } catch {
                log(.error, "the alarm sound failed on \(device ?? "the system default output"): \(error.logDescription)")
            }
        }
        finish(record.videoIds.isEmpty ? .failed : .played, error: reason)
    }

    // MARK: Recording

    private func finish(_ outcome: AlarmOutcome, error: String?) {
        guard !isAbandoned else { return log(.info, "cancelled: the alarm time changed.") }
        record.endedAt = .now
        record.outcome = outcome
        record.error = error
        host.recordAlarmRun(record, watchedIds: watched)
        let summary = "finished: \(outcome.rawValue), \(record.videoIds.count) video(s) started, \(watched.count) watched"
            + (error.map { ". \($0)" } ?? ".")
        let level: LogLevel = switch outcome {
        case .played, .stopped, .running: .info
        case .failed: .error
        case .alarmSound, .skippedLate: .warning
        }
        log(level, summary)
    }

    private func log(_ level: LogLevel, _ message: String) {
        host.logAlarm(level, "Alarm: \(message)")
    }

    static func describe(_ rule: FallbackRule) -> String {
        let channel = rule.channelId ?? "any channel"
        return rule.kind.usesDays ? "\(rule.kind.rawValue), \(channel), \(rule.withinDays) days" : "\(rule.kind.rawValue), \(channel)"
    }
}
