import Foundation
import Testing
@testable import Stow

struct AlarmTextTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    /// Wednesday 19 Nov 2025, 15:00 London.
    private var now: Date { calendar.date(from: DateComponents(year: 2025, month: 11, day: 19, hour: 15))! }

    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2025, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func nextAlarmNamesTodayTomorrowWeekdayOrDate() {
        #expect(AlarmText.nextAlarm(at(day: 19, hour: 23), now: now, calendar: calendar) == "Today 23:00")
        #expect(AlarmText.nextAlarm(at(day: 20, hour: 8), now: now, calendar: calendar) == "Tomorrow 08:00")
        #expect(AlarmText.nextAlarm(at(day: 24, hour: 8), now: now, calendar: calendar) == "Monday 08:00")
        let farOff = AlarmText.nextAlarm(at(day: 28, hour: 8), now: now, calendar: calendar)
        #expect(farOff.hasPrefix("Fri") && farOff.contains("28") && farOff.hasSuffix("08:00"))
    }

    @Test func countdownRoundsUpToTheMinute() {
        #expect(AlarmText.countdown(to: now, now: now) == "now")
        #expect(AlarmText.countdown(to: now.addingTimeInterval(30), now: now) == "in 1 min")
        #expect(AlarmText.countdown(to: now.addingTimeInterval(4 * 60), now: now) == "in 4 min")
        #expect(AlarmText.countdown(to: now.addingTimeInterval(17 * 3600), now: now) == "in 17 h")
        #expect(AlarmText.countdown(to: now.addingTimeInterval(9 * 3600 + 5 * 60), now: now) == "in 9 h 5 min")
        #expect(AlarmText.countdown(to: now.addingTimeInterval(3 * 86400), now: now) == "in 3 days")
        #expect(AlarmText.countdown(to: now.addingTimeInterval(-60), now: now) == "now")
    }

    @Test func togglingKeepsDaysSortedMondayFirst() {
        #expect(AlarmText.toggling(.sun, in: [.mon, .fri]) == [.mon, .fri, .sun])
        #expect(AlarmText.toggling(.wed, in: [.mon, .fri]) == [.mon, .wed, .fri])
        #expect(AlarmText.toggling(.mon, in: [.mon, .fri]) == [.fri])
        #expect(AlarmText.toggling(.mon, in: [.mon]).isEmpty)
    }

    @Test func weekdayLettersAndNamesFollowCalendarNumbering() {
        #expect(AlarmText.letter(.mon, calendar: calendar) == "M")
        #expect(AlarmText.name(.sun, calendar: calendar) == "Sunday")
        #expect(AlarmText.name(.sat, calendar: calendar) == "Saturday")
    }

    @Test func phaseWording() {
        let video = Video(id: "a", channelId: "c", channelTitle: "Chan", title: "Title", publishedAt: nil,
                          thumbnailURL: nil, isMembersOnly: false, liveStatus: .none)
        let playing = AlarmPhase.playing(index: 1, count: 3, video: video)
        #expect(AlarmText.phaseTitle(playing) == "Playing 2 of 3")
        #expect(AlarmText.phaseDetail(playing) == "Title · Chan")
        #expect(AlarmText.shortPhase(playing) == "Alarm: 2/3")
        #expect(AlarmText.phaseDetail(.starting(output: "JBL Go 3")) == "Opening the player on JBL Go 3")
        #expect(AlarmText.phaseDetail(.alarmSound(reason: "No internet")) == "No internet")
        #expect(AlarmText.phaseDetail(.idle) == nil)
        #expect(AlarmText.shortPhase(.idle).isEmpty)
    }

    @Test func ruleDescriptions() {
        #expect(AlarmText.describe(FallbackRule(kind: .mostRecentUnplayed, withinDays: 7), channelTitle: nil)
                == "The newest unplayed video from any channel, published in the last 7 days")
        #expect(AlarmText.describe(FallbackRule(kind: .randomUnplayed, channelId: "UC1", withinDays: 1), channelTitle: "Veritasium")
                == "A random unplayed video from Veritasium, published in the last day")
        #expect(AlarmText.describe(FallbackRule(kind: .replayLatest), channelTitle: nil)
                == "The newest video from any channel, even if it was played before")
    }

    @Test func runSummary() {
        let start = at(day: 19, hour: 8)
        var run = AlarmRunRecord(trigger: .scheduled, scheduledFor: start, startedAt: start,
                                 endedAt: start.addingTimeInterval(24 * 60), videoIds: ["a", "b"],
                                 output: "JBL Go 3", outcome: .played)
        #expect(AlarmText.outcomeTitle(run) == "Played 2 videos")
        let detail = AlarmText.runDetail(run, calendar: calendar)
        #expect(detail.hasPrefix("Scheduled · "))
        #expect(detail.hasSuffix(" · JBL Go 3 · 24 min"))
        run.videoIds = ["a"]
        #expect(AlarmText.outcomeTitle(run) == "Played 1 video")
        run.outcome = .skippedLate
        #expect(AlarmText.outcomeTitle(run) == "Skipped: the Mac woke too late")
        run.trigger = .test
        run.endedAt = start.addingTimeInterval(10)
        run.output = nil
        #expect(AlarmText.runDetail(run, calendar: calendar).hasPrefix("Test · "))
        #expect(AlarmText.runDetail(run, calendar: calendar).hasSuffix(" · under a minute"))
    }

    private let jbl = AudioOutput(uid: "40-C1-F6-88-8F-AF:output", name: "JBL Go 3", transport: .bluetooth, isDefault: false)
    private let crg = AudioOutput(uid: "CRG:output", name: "CRG", transport: .bluetooth, isDefault: true)
    private let monitor = AudioOutput(uid: "DP-1", name: "Mi monitor", transport: .displayPort, isDefault: false)
    private let builtIn = AudioOutput(uid: "BuiltIn", name: "Mac mini Speakers", transport: .builtIn, isDefault: false)

    @Test func speakerChoicesListDevicesThenOtherOutputsThenTheConfiguredOne() {
        let devices = [BluetoothAudioDevice(address: "40:C1:F6:88:8F:AF", name: "JBL Go 3", isConnected: true),
                       BluetoothAudioDevice(address: "00:11:22:33:44:55", name: "CRG", isConnected: true)]
        let choices = AlarmText.speakerChoices(devices: devices, outputs: [jbl, crg, monitor, builtIn], current: .default)
        #expect(choices.map(\.name) == ["JBL Go 3", "CRG", "Mi monitor", "Mac mini Speakers"])
        #expect(choices[0].address == "40:C1:F6:88:8F:AF")
        #expect(choices[2].address == nil)

        let missing = SpeakerSettings(name: "Old Speaker", address: "AA:BB:CC:DD:EE:FF", keepAlive: true, keepAliveLevel: -60)
        let withMissing = AlarmText.speakerChoices(devices: devices, outputs: [monitor], current: missing)
        #expect(withMissing.map(\.name) == ["JBL Go 3", "CRG", "Mi monitor", "Old Speaker"])
    }

    @Test func speakerChoiceIdIgnoresAddressFormatting() {
        #expect(SpeakerChoice(name: "JBL", address: "40:c1:f6:88:8f:af").id
                == SpeakerChoice(name: "JBL Go 3", address: "40-C1-F6-88-8F-AF").id)
        #expect(SpeakerChoice(name: "Mi Monitor", address: nil).id == SpeakerChoice(name: "mi monitor", address: nil).id)
    }

    @Test func playbackTimeLooksLikeYouTube() {
        #expect(AlarmText.playbackTime(7.9) == "0:07")
        #expect(AlarmText.playbackTime(725) == "12:05")
        #expect(AlarmText.playbackTime(3723) == "1:02:03")
        #expect(AlarmText.playbackTime(-3) == "0:00")
        #expect(AlarmText.playbackTime(.nan) == "0:00")
    }
}
