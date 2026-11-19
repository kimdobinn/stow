import Foundation
import Testing
@testable import Stow

struct AlarmModelsTests {
    private func decode(_ json: String) throws -> AlarmSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(#"{"alarm": \#(json)}"#.utf8)).alarm
    }

    @Test func missingAlarmUsesDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.alarm == .default)
        #expect(settings.alarm.time == AlarmTime(hour: 8, minute: 0))
        #expect(settings.alarm.days == [.mon, .tue, .wed, .thu, .fri])
        #expect(settings.alarm.fallbackRules == [FallbackRule(kind: .mostRecentUnplayed, withinDays: 7), FallbackRule(kind: .replayLatest)])
        #expect(settings.alarm.speaker.address == "40:C1:F6:88:8F:AF")
    }

    @Test func malformedValuesFallBackPerKey() throws {
        let alarm = try decode(#"""
        {"enabled": "yes", "time": "25:00", "days": ["SUN", "sat", "sat", "funday"], "maxVideos": 99,
         "volume": -5, "order": "shuffled", "maxDurationMinutes": 30, "fallbackOutput": "Mac mini Speakers"}
        """#)
        #expect(alarm.enabled == AlarmSettings.default.enabled)
        #expect(alarm.time == AlarmSettings.default.time)
        #expect(alarm.days == [.sat, .sun])
        #expect(alarm.maxVideos == AlarmSettings.maxVideosRange.upperBound)
        #expect(alarm.volume == 0)
        #expect(alarm.order == .oldestFirst)
        #expect(alarm.maxDurationMinutes == 30)
        #expect(alarm.fallbackOutput == "Mac mini Speakers")
    }

    @Test func replacedValuesAreReported() throws {
        let issues = SettingsIssues()
        let decoder = JSONDecoder()
        decoder.userInfo[.settingsIssues] = issues
        let json = #"""
        {"alarm": {"enabled": "maybe", "time": "half past seven", "days": ["Monday", "tues", "Funday"],
                   "order": "shuffled", "fallbackRules": [{"kind": "teleport"}, {"kind": "replayLatest"}]}}
        """#
        let alarm = try decoder.decode(AppSettings.self, from: Data(json.utf8)).alarm
        #expect(!alarm.enabled)
        #expect(alarm.time == AlarmSettings.default.time)
        #expect(alarm.days == [.mon, .tue])
        #expect(alarm.fallbackRules == [FallbackRule(kind: .replayLatest)])
        let messages = issues.messages.joined(separator: "\n")
        #expect(issues.messages.count == 5)
        for key in ["alarm.enabled", "alarm.time", "\"Funday\"", "alarm.order", "alarm.fallbackRules"] {
            #expect(messages.contains(key))
        }

        let clean = SettingsIssues()
        decoder.userInfo[.settingsIssues] = clean
        _ = try decoder.decode(AppSettings.self, from: Data(#"{"alarm": {"enabled": "off", "days": []}}"#.utf8))
        #expect(clean.messages.isEmpty)
    }

    @Test func enabledAcceptsCommonSpellings() throws {
        #expect(try decode(#"{"enabled": "off"}"#).enabled == false)
        #expect(try decode(#"{"enabled": 0}"#).enabled == false)
        #expect(try decode(#"{"enabled": "Yes"}"#).enabled == true)
        #expect(try decode(#"{"enabled": null}"#).enabled == true)
    }

    @Test func alarmThatIsNotAnObjectKeepsChannels() throws {
        let json = #"{"alarm": "off", "channels": [{"id": "UC-XMoeMXbYrMlvmyLSwDd3g"}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.alarm == .default)
        #expect(settings.channels.count == 1)
    }

    @Test func fallbackRulesDropUnknownKindsAndKeepOrder() throws {
        let alarm = try decode(#"""
        {"fallbackRules": [{"kind": "randomUnplayed", "channelId": "UCabc", "withinDays": 3},
                           {"kind": "teleport"}, {"channelId": "UCabc"},
                           {"kind": "replayLatest", "channelId": null}, {"kind": "mostRecentUnplayed", "withinDays": 0}]}
        """#)
        #expect(alarm.fallbackRules == [
            FallbackRule(kind: .randomUnplayed, channelId: "UCabc", withinDays: 3),
            FallbackRule(kind: .replayLatest),
            FallbackRule(kind: .mostRecentUnplayed, withinDays: 1),
        ])
    }

    @Test func emptyRuleListStaysEmpty() throws {
        #expect(try decode(#"{"fallbackRules": []}"#).fallbackRules.isEmpty)
    }

    @Test func speakerAddressNullMeansNotBluetooth() throws {
        let alarm = try decode(#"{"speaker": {"name": "Mi monitor", "address": null, "keepAliveLevel": -200}}"#)
        #expect(alarm.speaker.name == "Mi monitor")
        #expect(alarm.speaker.address == nil)
        #expect(alarm.speaker.keepAlive)
        #expect(alarm.speaker.keepAliveLevel == SpeakerSettings.keepAliveLevelRange.lowerBound)
    }

    @Test func alarmRoundTripsThroughStoreEncoding() throws {
        var settings = AppSettings.default
        settings.alarm.time = AlarmTime(hour: 6, minute: 5)
        settings.alarm.speaker.address = nil
        settings.alarm.fallbackRules = [FallbackRule(kind: .replayLatest, channelId: "UCabc")]
        let data = try Store.encoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""time" : "06:05""#))
        #expect(text.contains(#""days" : ["#))
        #expect(!text.contains("withinDays"))
        #expect(try Store.decoder().decode(AppSettings.self, from: data) == settings)
    }

    @Test func alarmTimeParsing() {
        #expect(AlarmTime(string: "7:30") == AlarmTime(hour: 7, minute: 30))
        #expect(AlarmTime(string: " 07:30:00 ") == AlarmTime(hour: 7, minute: 30))
        #expect(AlarmTime(string: "7") == nil)
        #expect(AlarmTime(string: "07:60") == nil)
        #expect(AlarmTime(string: "07.30") == AlarmTime(hour: 7, minute: 30))
        #expect(AlarmTime(string: "7:30 am") == AlarmTime(hour: 7, minute: 30))
        #expect(AlarmTime(string: "7:30PM") == AlarmTime(hour: 19, minute: 30))
        #expect(AlarmTime(string: "12am") == AlarmTime(hour: 0, minute: 0))
        #expect(AlarmTime(string: "12:15 pm") == AlarmTime(hour: 12, minute: 15))
        #expect(AlarmTime(string: "13:00 pm") == nil)
        #expect(AlarmTime(hour: 23, minute: 5).string == "23:05")
    }

    @Test func weekdayCalendarMapping() {
        for day in Weekday.allCases {
            #expect(Weekday(calendarWeekday: day.calendarWeekday) == day)
        }
        #expect(Weekday(calendarWeekday: 1) == .sun)
        #expect(Weekday.allCases.sorted() == [.mon, .tue, .wed, .thu, .fri, .sat, .sun])
    }

    @Test func stateDecodesAlarmFieldsAndToleratesUnknownOutcome() throws {
        let json = #"""
        {"alarmPlayedIds": ["a"], "watchedIds": ["b"],
         "lastAlarmRun": {"trigger": "scheduled", "scheduledFor": "2026-11-19T08:00:00Z", "startedAt": "2026-11-19T08:00:01Z",
                          "videoIds": ["a"], "outcome": "exploded"}}
        """#
        let state = try Store.decoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.alarmPlayedIds == ["a"])
        #expect(state.watchedIds == ["b"])
        #expect(state.lastAlarmRun == nil)
    }

    @Test func speakerOutputMatchesByAddressThenName() {
        let outputs = [
            AudioOutput(uid: "BuiltInSpeakerDevice", name: "Mac mini Speakers", transport: .builtIn, isDefault: false),
            AudioOutput(uid: "40-c1-f6-88-8f-af:output", name: "Kitchen", transport: .bluetooth, isDefault: false),
            AudioOutput(uid: "DP-1", name: "Mi monitor", transport: .displayPort, isDefault: true),
        ]
        #expect(AudioOutput.matching(SpeakerSettings.default, in: outputs)?.name == "Kitchen")
        let byName = SpeakerSettings(name: "mi MONITOR", address: nil, keepAlive: false, keepAliveLevel: -60)
        #expect(AudioOutput.matching(byName, in: outputs)?.uid == "DP-1")
        #expect(AudioOutput.named("Mac mini", in: outputs)?.uid == "BuiltInSpeakerDevice")
        #expect(AudioOutput.named("  ", in: outputs) == nil)
        let missing = SpeakerSettings(name: "JBL Go 3", address: "00:00:00:00:00:01", keepAlive: true, keepAliveLevel: -60)
        #expect(AudioOutput.matching(missing, in: outputs) == nil)
    }
}
