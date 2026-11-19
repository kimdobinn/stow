import Foundation

/// Wording and small decisions for the Alarm section, kept free of SwiftUI so they can be tested.
enum AlarmText {
    // MARK: Schedule

    /// "Today 08:00", "Tomorrow 08:00", "Friday 08:00" within a week, else "Mon 1 Dec 08:00".
    static func nextAlarm(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(style(calendar).hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today \(time)"
        case 1: return "Tomorrow \(time)"
        case 2..<7: return "\(date.formatted(style(calendar).weekday(.wide))) \(time)"
        default: return "\(date.formatted(style(calendar).weekday(.abbreviated).day().month(.abbreviated))) \(time)"
        }
    }

    /// "in 9 h 5 min", "in 4 min", "in 2 days" (rounded up to the minute).
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 1 { return "now" }
        if minutes >= 48 * 60 { return "in \(minutes / (24 * 60)) days" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "in \(rest) min" }
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    /// The day list after clicking `day`: added or removed, kept Monday-first.
    static func toggling(_ day: Weekday, in days: [Weekday]) -> [Weekday] {
        days.contains(day) ? days.filter { $0 != day } : (days + [day]).sorted()
    }

    static func letter(_ day: Weekday, calendar: Calendar = .current) -> String {
        calendar.veryShortStandaloneWeekdaySymbols[day.calendarWeekday - 1]
    }

    static func name(_ day: Weekday, calendar: Calendar = .current) -> String {
        calendar.standaloneWeekdaySymbols[day.calendarWeekday - 1]
    }

    // MARK: Phase

    static func phaseTitle(_ phase: AlarmPhase) -> String {
        switch phase {
        case .idle: "Idle"
        case .preparing: "Getting ready"
        case .starting: "Starting"
        case .playing(let index, let count, _): "Playing \(index + 1) of \(count)"
        case .alarmSound: "Alarm sound ringing"
        }
    }

    static func phaseDetail(_ phase: AlarmPhase, calendar: Calendar = .current) -> String? {
        switch phase {
        case .idle: nil
        case .preparing(let date):
            "Alarm at \(date.formatted(style(calendar).hour().minute())) · connecting the speaker and fetching videos"
        case .starting(let output): output.map { "Opening the player on \($0)" } ?? "Opening the player"
        case .playing(_, _, let video): "\(video.title) · \(video.channelTitle)"
        case .alarmSound(let reason): reason
        }
    }

    /// Toolbar wording: "Alarm: getting ready", "Alarm: 1/3", "Alarm ringing".
    static func shortPhase(_ phase: AlarmPhase) -> String {
        switch phase {
        case .idle: ""
        case .preparing: "Alarm: getting ready"
        case .starting: "Alarm: starting"
        case .playing(let index, let count, _): "Alarm: \(index + 1)/\(count)"
        case .alarmSound: "Alarm ringing"
        }
    }

    // MARK: Fallback rules

    static func kindTitle(_ kind: FallbackRuleKind) -> String {
        switch kind {
        case .mostRecentUnplayed: "Newest unplayed"
        case .randomUnplayed: "Random unplayed"
        case .replayLatest: "Replay newest"
        }
    }

    /// One sentence, e.g. "The newest unplayed video from any channel, published in the last 7 days".
    static func describe(_ rule: FallbackRule, channelTitle: String?) -> String {
        let source = channelTitle ?? "any channel"
        let days = rule.withinDays == 1 ? "day" : "\(rule.withinDays) days"
        switch rule.kind {
        case .mostRecentUnplayed: return "The newest unplayed video from \(source), published in the last \(days)"
        case .randomUnplayed: return "A random unplayed video from \(source), published in the last \(days)"
        case .replayLatest: return "The newest video from \(source), even if it was played before"
        }
    }

    // MARK: Last run

    static func outcomeTitle(_ run: AlarmRunRecord) -> String {
        switch run.outcome {
        case .running: "In progress"
        case .played: run.videoIds.count == 1 ? "Played 1 video" : "Played \(run.videoIds.count) videos"
        case .alarmSound: "Rang the alarm sound"
        case .skippedLate: "Skipped: the Mac woke too late"
        case .stopped: "Stopped before anything played"
        case .failed: "Failed"
        }
    }

    /// "Test · Thu 20 Nov 08:00 · JBL Go 3 · 24 min".
    static func runDetail(_ run: AlarmRunRecord, calendar: Calendar = .current) -> String {
        var parts = [run.trigger == .test ? "Test" : "Scheduled",
                     run.startedAt.formatted(style(calendar).weekday(.abbreviated).day().month(.abbreviated).hour().minute())]
        if let output = run.output { parts.append(output) }
        if let end = run.endedAt {
            let minutes = Int((end.timeIntervalSince(run.startedAt) / 60).rounded())
            parts.append(minutes < 1 ? "under a minute" : "\(minutes) min")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Outputs

    /// Speaker picker entries: paired Bluetooth audio devices, then outputs that aren't one of
    /// them, then the configured speaker if it is in neither list.
    static func speakerChoices(devices: [BluetoothAudioDevice], outputs: [AudioOutput],
                               current: SpeakerSettings) -> [SpeakerChoice] {
        var choices = devices.map { SpeakerChoice(name: $0.name, address: $0.address) }
        for output in outputs where !devices.contains(where: { $0.describes(output) }) {
            choices.append(SpeakerChoice(name: output.name, address: nil))
        }
        let configured = SpeakerChoice(name: current.name, address: current.address)
        if !choices.contains(where: { $0.id == configured.id }) { choices.append(configured) }
        return choices
    }

    private static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }
}

/// A speaker the user can pick: Bluetooth (with an address) or any other output (by name).
struct SpeakerChoice: Hashable, Identifiable {
    var name: String
    var address: String?

    var id: String { address.map(AudioOutput.normalizedAddress) ?? name.lowercased() }
}

private extension BluetoothAudioDevice {
    func describes(_ output: AudioOutput) -> Bool {
        AudioOutput.matching(SpeakerSettings(name: name, address: address, keepAlive: false, keepAliveLevel: 0), in: [output]) != nil
    }
}
