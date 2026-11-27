import Foundation
import Testing
@testable import Stow

struct VersionTests {
    @Test func parsesVersionsAndTags() throws {
        #expect(DottedVersion("0.2.0")?.parts == [0, 2, 0])
        #expect(DottedVersion("v1.10")?.parts == [1, 10])
        #expect(DottedVersion("mac-v0.3.1", prefix: "mac-v")?.parts == [0, 3, 1])
        #expect(DottedVersion("2026.11.23")?.description == "2026.11.23")
        #expect(DottedVersion(" 0.1.0\n")?.description == "0.1.0")
    }

    @Test func rejectsOtherText() {
        #expect(DottedVersion("") == nil)
        #expect(DottedVersion("0.2.0-beta") == nil)
        #expect(DottedVersion("1..2") == nil)
        #expect(DottedVersion("ios-v0.1.0", prefix: "mac-v") == nil)
        #expect(DottedVersion("v0.8.1", prefix: "mac-v") == nil)
        #expect(DottedVersion("mac-v", prefix: "mac-v") == nil)
        #expect(DottedVersion("١.٢") == nil)
    }

    @Test func comparesNumerically() throws {
        func v(_ text: String) -> DottedVersion { DottedVersion(text)! }
        #expect(v("0.10.0") > v("0.9.9"))
        #expect(v("0.2.0") > v("0.1.12"))
        #expect(v("1.0") == v("1.0.0"))
        #expect(v("1.0").hashValue == v("1.0.0").hashValue)
        #expect(v("1.0.1") > v("1.0"))
        #expect(!(v("0.1.0") < v("0.1.0")))
        #expect(v("2026.11.23") > v("2026.10.26"))
        #expect(v("2026.11.23.1") > v("2026.11.23"))
        #expect([v("0.3.0"), v("0.10.0"), v("0.9.0")].max() == v("0.10.0"))
    }

    @Test func roundTripsThroughJSON() throws {
        let version = DottedVersion("0.4.2")!
        let data = try JSONEncoder().encode([version])
        #expect(String(decoding: data, as: UTF8.self) == #"["0.4.2"]"#)
        #expect(try JSONDecoder().decode([DottedVersion].self, from: data) == [version])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([DottedVersion].self, from: Data(#"["x"]"#.utf8)) }
    }

    @Test func gateBlocksWhileTheAlarmRunsOrIsNear() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateGate.block(alarmRunning: true, nextAlarm: nil, now: now) == .alarmRunning)
        #expect(UpdateGate.block(alarmRunning: false, nextAlarm: nil, now: now) == nil)
        #expect(UpdateGate.block(alarmRunning: false, nextAlarm: now.addingTimeInterval(9 * 60), now: now) == .alarmDue(now.addingTimeInterval(9 * 60)))
        #expect(UpdateGate.block(alarmRunning: false, nextAlarm: now.addingTimeInterval(11 * 60), now: now) == nil)
        #expect(UpdateGate.block(alarmRunning: false, nextAlarm: now.addingTimeInterval(-60), now: now) != nil)
        #expect(UpdateGate.Block.alarmRunning.appMessage == "The alarm is running. Update after it ends.")
    }

    @Test func dailyCheckIsDueOnceADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DailyCheck.isDue(lastChecked: nil, now: now))
        #expect(!DailyCheck.isDue(lastChecked: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(DailyCheck.isDue(lastChecked: now.addingTimeInterval(-24 * 3600), now: now))
        // A last check "in the future" (the clock went back) doesn't stop checks for good.
        #expect(DailyCheck.isDue(lastChecked: now.addingTimeInterval(3600), now: now))
    }
}
