import Foundation

/// When updates may run: never while the alarm runs or within 10 minutes of it.
enum UpdateGate {
    static let alarmMargin: TimeInterval = 10 * 60

    enum Block: Equatable, Sendable {
        case alarmRunning
        case alarmDue(Date)

        /// Why Stow can't update now.
        var appMessage: String {
            switch self {
            case .alarmRunning: "The alarm is running. Update after it ends."
            case .alarmDue(let date): "The alarm goes off at \(date.formatted(date: .omitted, time: .shortened)). Update after it."
            }
        }

        /// Why yt-dlp's update waits.
        var ytDlpMessage: String {
            switch self {
            case .alarmRunning: "Waiting for the alarm to end."
            case .alarmDue(let date): "Waiting until after the \(date.formatted(date: .omitted, time: .shortened)) alarm."
            }
        }
    }

    /// What stops an update now, or nil when it may go ahead.
    static func block(alarmRunning: Bool, nextAlarm: Date?, now: Date = .now) -> Block? {
        if alarmRunning { return .alarmRunning }
        if let nextAlarm, abs(nextAlarm.timeIntervalSince(now)) < alarmMargin { return .alarmDue(nextAlarm) }
        return nil
    }
}

/// "At most once a day": a check is due when the last one is a day old (or in the future, after a
/// clock change).
enum DailyCheck {
    static let interval: TimeInterval = 24 * 60 * 60
    /// How often a due check is looked for while the app runs.
    static let tick: Duration = .seconds(60 * 60)

    static func isDue(lastChecked: Date?, now: Date = .now) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval || lastChecked > now.addingTimeInterval(60)
    }
}
