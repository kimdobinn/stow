import Foundation
import Testing
@testable import Stow

struct AlarmScheduleTests {
    /// New York: DST starts 2026-03-08 02:00 (→ 03:00) and ends 2026-11-01 02:00 (→ 01:00).
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func settings(_ time: String = "08:00", days: [Weekday] = [.mon, .tue, .wed, .thu, .fri], enabled: Bool = true) -> AlarmSettings {
        var settings = AlarmSettings.default
        settings.time = AlarmTime(string: time)!
        settings.days = days
        settings.enabled = enabled
        return settings
    }

    func next(after date: Date, _ settings: AlarmSettings, handled: Date? = nil) -> Date? {
        AlarmSchedule.nextFire(after: date, handled: handled, settings: settings, calendar: Self.calendar)
    }

    // 2026-11-18 is a Wednesday.
    @Test func todayWhenStillAhead() {
        #expect(next(after: Self.date(2026, 11, 18, 7, 59), settings()) == Self.date(2026, 11, 18, 8))
    }

    @Test func tomorrowOnceTheTimeHasCome() {
        #expect(next(after: Self.date(2026, 11, 18, 8), settings()) == Self.date(2026, 11, 19, 8))
        #expect(next(after: Self.date(2026, 11, 18, 9), settings()) == Self.date(2026, 11, 19, 8))
    }

    @Test func skipsToTheNextChosenWeekday() {
        // Friday after the alarm → Monday.
        #expect(next(after: Self.date(2026, 11, 20, 9), settings()) == Self.date(2026, 11, 23, 8))
        // Only Sundays.
        #expect(next(after: Self.date(2026, 11, 18, 9), settings(days: [.sun])) == Self.date(2026, 11, 22, 8))
        // Saturday and Sunday, from Saturday morning before the alarm.
        #expect(next(after: Self.date(2026, 11, 21, 6), settings(days: [.sat, .sun])) == Self.date(2026, 11, 21, 8))
    }

    @Test func offOrNoDaysNeverFires() {
        #expect(next(after: Self.date(2026, 11, 18, 7), settings(enabled: false)) == nil)
        #expect(next(after: Self.date(2026, 11, 18, 7), settings(days: [])) == nil)
    }

    @Test func handledTimesAreSkipped() {
        let eight = Self.date(2026, 11, 18, 8)
        #expect(next(after: Self.date(2026, 11, 18, 7, 59), settings(), handled: eight) == Self.date(2026, 11, 19, 8))
    }

    @Test func keepsWallClockTimeAcrossDSTChanges() {
        // Friday before spring forward → Monday 08:00 EDT, not 09:00 or 07:00.
        let monday = next(after: Self.date(2026, 3, 6, 9), settings())!
        #expect(Self.calendar.dateComponents([.day, .hour, .minute], from: monday) == DateComponents(day: 9, hour: 8, minute: 0))
        #expect(monday.timeIntervalSince(Self.date(2026, 3, 6, 8)) == 3 * 86_400 - 3600)
        // Friday before fall back → Monday 08:00 EST.
        let after = next(after: Self.date(2026, 10, 30, 9), settings())!
        #expect(Self.calendar.dateComponents([.day, .hour], from: after) == DateComponents(day: 2, hour: 8))
    }

    @Test func timeSkippedBySpringForwardFiresAtTheEndOfTheGap() {
        let fire = next(after: Self.date(2026, 3, 7, 12), settings("02:30", days: [.sun]))!
        // 02:30 doesn't exist on 2026-03-08; 03:00 EDT is 07:00 UTC.
        #expect(fire == Date(timeIntervalSince1970: 1_772_953_200))
        #expect(Self.calendar.component(.hour, from: fire) == 3)
    }

    @Test func repeatedTimeAtFallBackFiresOnce() {
        let fire = next(after: Self.date(2026, 10, 31, 12), settings("01:30", days: [.sun]))!
        // The first 01:30 (EDT) is 05:30 UTC.
        #expect(fire == Date(timeIntervalSince1970: 1_793_511_000))
        // Once handled, the repeated 01:30 (EST) an hour later doesn't fire again.
        #expect(next(after: fire.addingTimeInterval(1800), settings("01:30", days: [.sun]), handled: fire)
                == Self.date(2026, 11, 8, 1, 30))
    }

    // MARK: step

    func step(now: Date, since: Date, handled: Date? = nil) -> AlarmSchedule.Step {
        AlarmSchedule.step(now: now, since: since, handled: handled, settings: settings(), calendar: Self.calendar)
    }

    @Test func waitsUntilThePrepWindow() {
        let since = Self.date(2026, 11, 18, 7)
        #expect(step(now: Self.date(2026, 11, 18, 7, 56), since: since) == .wait(next: Self.date(2026, 11, 18, 8)))
        #expect(step(now: Self.date(2026, 11, 18, 7, 57), since: since) == .run(fireDate: Self.date(2026, 11, 18, 8)))
    }

    @Test func runsWhenNoticedUpToTenMinutesLate() {
        let since = Self.date(2026, 11, 18, 7)
        #expect(step(now: Self.date(2026, 11, 18, 8, 10), since: since) == .run(fireDate: Self.date(2026, 11, 18, 8)))
        #expect(step(now: Self.date(2026, 11, 18, 8, 11), since: since) == .skipLate(fireDate: Self.date(2026, 11, 18, 8)))
    }

    @Test func lateWakeSkipsThenWaitsForTheNextDay() {
        let eight = Self.date(2026, 11, 18, 8)
        let noon = Self.date(2026, 11, 18, 12)
        #expect(step(now: noon, since: Self.date(2026, 11, 18, 6)) == .skipLate(fireDate: eight))
        #expect(step(now: noon, since: Self.date(2026, 11, 18, 6), handled: eight) == .wait(next: Self.date(2026, 11, 19, 8)))
    }

    @Test func timesBeforeTheLastLookAreIgnored() {
        // The app launched at noon: this morning's alarm was before it looked, so it isn't "late".
        #expect(step(now: Self.date(2026, 11, 18, 12), since: Self.date(2026, 11, 18, 11, 50))
                == .wait(next: Self.date(2026, 11, 19, 8)))
    }

    @Test func handledTimeNeverRunsTwice() {
        let eight = Self.date(2026, 11, 18, 8)
        #expect(step(now: Self.date(2026, 11, 18, 8, 1), since: Self.date(2026, 11, 18, 7, 59), handled: eight)
                == .wait(next: Self.date(2026, 11, 19, 8)))
    }

    @Test func isScheduledFollowsSettingEdits() {
        let eight = Self.date(2026, 11, 18, 8)
        #expect(AlarmSchedule.isScheduled(eight, settings: settings(), calendar: Self.calendar))
        #expect(!AlarmSchedule.isScheduled(eight, settings: settings("08:05"), calendar: Self.calendar))
        #expect(!AlarmSchedule.isScheduled(eight, settings: settings(days: [.sat]), calendar: Self.calendar))
        #expect(!AlarmSchedule.isScheduled(eight, settings: settings(enabled: false), calendar: Self.calendar))
    }
}
