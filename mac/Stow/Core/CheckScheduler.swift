import AppKit

/// Fires `action` every interval and shortly after the Mac wakes from sleep.
@MainActor
final class CheckScheduler {
    /// Gives Wi-Fi time to reconnect after wake.
    static let wakeDelay: Duration = .seconds(20)

    private let interval: TimeInterval
    private let action: @MainActor (CheckTrigger) async -> Void
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var wakeTask: Task<Void, Never>?

    init(interval: Duration, action: @escaping @MainActor (CheckTrigger) async -> Void) {
        self.interval = TimeInterval(interval.components.seconds)
        self.action = action
    }

    func start() {
        stop()
        scheduleTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        wakeTask?.cancel()
        wakeTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.action(.scheduled) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Restarts the timer so a timer that fired during sleep doesn't double up with the wake check.
    private func handleWake() {
        scheduleTimer()
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.wakeDelay)
            guard !Task.isCancelled else { return }
            await self?.action(.wake)
        }
    }
}
