import Foundation

/// When the alarm fires. Pure: the clock and calendar are passed in.
enum AlarmSchedule {
    /// Prep (speaker, feeds, video details) starts this long before the alarm time.
    static let prepLead: TimeInterval = 3 * 60
    /// An alarm noticed later than this after its time (the Mac was asleep) is skipped.
    static let lateLimit: TimeInterval = 10 * 60

    enum Step: Equatable {
        /// Nothing to do yet; `next` is the coming alarm time, if any.
        case wait(next: Date?)
        /// Start the run for `fireDate`: prep now, play at `fireDate` (at once if it has passed).
        case run(fireDate: Date)
        /// `fireDate` passed more than `lateLimit` ago without running.
        case skipLate(fireDate: Date)
    }

    /// The first alarm time strictly after `date` on one of `days`, in `calendar`'s time zone.
    /// A time that a DST change skips fires at the end of the gap; a repeated time fires only the first time.
    static func nextFire(after date: Date, time: AlarmTime, days: [Weekday], calendar: Calendar) -> Date? {
        var from = date
        for _ in 0..<2 {
            let candidate = days.compactMap { day in
                calendar.nextDate(
                    after: from,
                    matching: DateComponents(hour: time.hour, minute: time.minute, second: 0, weekday: day.calendarWeekday),
                    matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            }.min()
            guard let candidate else { return nil }
            // After the first occurrence of a repeated time, `nextDate` finds the second one.
            let wallClock = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: candidate)
            guard let first = calendar.date(from: wallClock), first < candidate else { return candidate }
            from = candidate
        }
        return nil
    }

    /// The coming alarm time for `settings`, ignoring times up to `handled`.
    static func nextFire(after now: Date, handled: Date?, settings: AlarmSettings, calendar: Calendar) -> Date? {
        guard settings.enabled else { return nil }
        return nextFire(after: max(now, handled ?? .distantPast), time: settings.time, days: settings.days, calendar: calendar)
    }

    /// What to do at `now`. Alarm times after `since` (when the schedule was last looked at) and
    /// after `handled` (the last alarm time already run or skipped) are considered, so an alarm
    /// that passed while the Mac slept is noticed on wake, and none fires twice.
    static func step(now: Date, since: Date, handled: Date?, settings: AlarmSettings, calendar: Calendar) -> Step {
        guard let fire = nextFire(after: since, handled: handled, settings: settings, calendar: calendar) else {
            return .wait(next: nil)
        }
        if now.timeIntervalSince(fire) > lateLimit { return .skipLate(fireDate: fire) }
        if fire.timeIntervalSince(now) <= prepLead { return .run(fireDate: fire) }
        return .wait(next: fire)
    }

    /// Whether `fireDate` is still one of the alarm times under `settings` (e.g. after the time was edited).
    static func isScheduled(_ fireDate: Date, settings: AlarmSettings, calendar: Calendar) -> Bool {
        nextFire(after: fireDate.addingTimeInterval(-1), handled: nil, settings: settings, calendar: calendar) == fireDate
    }
}
