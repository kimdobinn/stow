import AppKit

/// Calls `tick` every `interval` and as soon as the Mac wakes. The controller re-reads the
/// settings and re-plans on every tick, so hand edits and missed alarms are noticed quickly.
@MainActor
final class AlarmScheduler {
    private let interval: TimeInterval
    private let tick: @MainActor () -> Void
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// Keeps App Nap from delaying the timer while an alarm is set.
    private var activity: NSObjectProtocol?

    init(interval: Duration, tick: @escaping @MainActor () -> Void) {
        self.interval = TimeInterval(interval.components.seconds)
        self.tick = tick
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        preventAppNap(false)
    }

    /// Idempotent.
    func preventAppNap(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Morning alarm is set")
        } else if !on, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
