import Foundation
import Observation

/// Owns the alarm: schedule, keep-alive, power assertion, prep and run.
/// AppModel.swift (frozen) uses only `init(services:)`, `host`, `start()` and `settingsDidChange()`;
/// the UI reaches the rest through AppModel+Alarm.swift.
@MainActor
@Observable
final class AlarmController {
    static let tickInterval: Duration = .seconds(20)
    static let keepAliveTestDuration: Duration = .seconds(5)
    static let soundTestDuration: Duration = .seconds(2)

    @ObservationIgnored weak var host: (any AlarmHost)?
    @ObservationIgnored let services: AlarmServices
    @ObservationIgnored var calendar = Calendar.autoupdatingCurrent

    let devices: AlarmDevices
    private(set) var phase: AlarmPhase = .idle
    /// The last scheduled alarm time that was run or skipped, so none fires twice.
    private(set) var handledFireDate: Date?

    @ObservationIgnored private var settings = AlarmSettings.default
    @ObservationIgnored private var scheduler: AlarmScheduler?
    /// Alarm times up to this were already looked at (settable for tests).
    @ObservationIgnored var evaluatedSince = Date.now
    @ObservationIgnored private var runner: AlarmRunner?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    /// `handledFireDate` before the running scheduled run, restored if that run is abandoned.
    @ObservationIgnored private var handledBeforeRun: Date?
    @ObservationIgnored private var watchers: [Task<Void, Never>] = []
    @ObservationIgnored private var evaluationQueued = false

    init(services: AlarmServices) {
        self.services = services
        devices = AlarmDevices(services: services)
        devices.log = { [weak self] level, message in self?.host?.logAlarm(level, message) }
        devices.refresh(settings, manageKeepAlive: false)
    }

    /// Called once by `AppModel.start()` after settings and state are loaded.
    func start() {
        guard scheduler == nil, let host else { return }
        // An alarm time up to 10 minutes ago still fires when only the app restarted (crash, update),
        // but not when the Mac itself started up after it: then someone has just switched it on.
        evaluatedSince = max(Date.now.addingTimeInterval(-AlarmSchedule.lateLimit), Self.bootTime ?? .distantPast)
        handledFireDate = host.currentState.lastScheduledAlarm
        let scheduler = AlarmScheduler(interval: Self.tickInterval) { [weak self] in self?.tick() }
        self.scheduler = scheduler
        scheduler.start()
        watch(services.outputs.changes())
        watch(services.speaker.changes())
        tick()
    }

    /// Called by AppModel after every settings save or reload (including hand edits it noticed).
    /// Deferred, because it runs inside AppModel's settings reload.
    func settingsDidChange() {
        guard scheduler != nil, !evaluationQueued else { return }
        evaluationQueued = true
        Task { [weak self] in
            self?.evaluationQueued = false
            self?.tick()
        }
    }

    /// The coming alarm time (today's while it is being prepared).
    func nextFireDate(for settings: AlarmSettings, now: Date = .now) -> Date? {
        if case .preparing(let date) = phase, runner?.trigger == .scheduled { return date }
        return AlarmSchedule.nextFire(after: now, handled: handledFireDate, settings: settings, calendar: calendar)
    }

    // MARK: Schedule

    /// Re-reads the settings, keeps the power assertion and keep-alive in step, and starts or
    /// skips any alarm that is due.
    func tick(now: Date = .now) {
        guard let host else { return }
        settings = host.currentSettings().alarm
        let armed = settings.enabled && !settings.days.isEmpty
        services.power.holdSystemAwake(armed)
        scheduler?.preventAppNap(armed)
        devices.refresh(settings, manageKeepAlive: true)
        abandonPrepIfRescheduled()

        // Bounded: each pass handles one alarm time; a long sleep may have skipped several.
        for _ in 0..<16 {
            let step = AlarmSchedule.step(now: now, since: evaluatedSince, handled: handledFireDate,
                                          settings: settings, calendar: calendar)
            switch step {
            case .wait:
                evaluatedSince = now
                return
            case .run(let fireDate):
                if runner?.trigger == .test { endTestRun(for: fireDate) }
                guard runner == nil else {
                    handledFireDate = fireDate
                    host.logAlarm(.warning, "Alarm: skipped the \(Self.format(fireDate)) alarm because another alarm is running.")
                    continue
                }
                handledBeforeRun = handledFireDate
                handledFireDate = fireDate
                startRun(.scheduled, at: fireDate)
                evaluatedSince = now
                return
            case .skipLate(let fireDate):
                handledFireDate = fireDate
                skipLate(fireDate, now: now)
            }
        }
    }

    private func skipLate(_ fireDate: Date, now: Date) {
        guard let host else { return }
        let late = Int(now.timeIntervalSince(fireDate) / 60)
        host.recordAlarmRun(AlarmRunRecord(trigger: .scheduled, scheduledFor: fireDate, startedAt: now, endedAt: now,
                                           videoIds: [], outcome: .skippedLate,
                                           error: "The Mac was asleep; noticed \(late) min late."),
                            watchedIds: [])
        host.logAlarm(.warning, "Alarm: skipped the \(Self.format(fireDate)) alarm: the Mac was asleep and woke \(late) min late.")
    }

    /// A scheduled run still preparing for a time the settings no longer contain is cancelled.
    private func abandonPrepIfRescheduled() {
        guard let runner, runner.trigger == .scheduled, case .preparing = phase,
              !AlarmSchedule.isScheduled(runner.scheduledFor, settings: settings, calendar: calendar) else { return }
        runner.abandon()
        runTask?.cancel()
        clearRun()
        handledFireDate = handledBeforeRun
    }

    /// The real alarm wins over a test that is still running.
    private func endTestRun(for fireDate: Date) {
        host?.logAlarm(.info, "Alarm: stopped the test alarm for the \(Self.format(fireDate)) alarm.")
        runner?.stop()
        runTask?.cancel()
        clearRun()
    }

    // MARK: Runs

    func testNow() {
        guard runner == nil else { return }
        startRun(.test, at: .now)
    }

    /// Stops prep, mpv or the alarm sound. A second press cancels whatever is still waiting.
    func stop() {
        services.sound.stop()
        guard let runner else { return }
        if case .preparing = phase { runTask?.cancel() }
        if runner.isStopping { runTask?.cancel() }
        runner.stop()
    }

    private func startRun(_ trigger: AlarmTrigger, at date: Date) {
        guard let host else { return }
        let id = UUID()
        let runner = AlarmRunner(trigger: trigger, scheduledFor: date, services: services, host: host) { [weak self] phase in
            // An abandoned run may still be winding down; it no longer owns the phase.
            if self?.runID == id { self?.phase = phase }
        }
        self.runner = runner
        runID = id
        phase = .preparing(scheduledFor: date)
        runTask = Task { [weak self] in
            await runner.run()
            guard let self, runID == id else { return }
            clearRun()
            refreshDevices()
        }
    }

    private func clearRun() {
        runner = nil
        runID = nil
        runTask = nil
        phase = .idle
    }

    // MARK: Devices

    private func watch(_ changes: AsyncStream<Void>) {
        watchers.append(Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                devices.refresh(settings, manageKeepAlive: true)
            }
        })
    }

    func refreshDevices() {
        if let host { settings = host.currentSettings().alarm }
        devices.refresh(settings, manageKeepAlive: scheduler != nil)
    }

    func connectSpeaker() async -> Bool {
        guard let host else { return false }
        let connected = await devices.connect(host.currentSettings().alarm.speaker)
        refreshDevices()
        return connected
    }

    func testSound() async {
        guard runner == nil, !services.sound.isPlaying, let host else { return }
        await devices.testSound(host.currentSettings().alarm, duration: Self.soundTestDuration)
    }

    func testKeepAlive() async {
        guard let host else { return }
        await devices.testKeepAlive(host.currentSettings().alarm.speaker, duration: Self.keepAliveTestDuration)
        refreshDevices()
    }

    #if DEBUG
    func previewPhase(_ phase: AlarmPhase) {
        self.phase = phase
    }
    #endif

    /// When the Mac last started up (sleep doesn't count).
    private static var bootTime: Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
