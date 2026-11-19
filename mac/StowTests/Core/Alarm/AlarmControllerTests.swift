import Foundation
import Testing
@testable import Stow

@MainActor
struct AlarmControllerTests {
    let fakes = FakeAlarmServices()
    let host = FakeAlarmHost()

    func makeController(since: Date) -> AlarmController {
        let controller = AlarmController(services: fakes.services)
        controller.calendar = AlarmScheduleTests.calendar
        controller.host = host
        controller.evaluatedSince = since
        return controller
    }

    func date(_ hour: Int, _ minute: Int = 0) -> Date { AlarmScheduleTests.date(2026, 11, 18, hour, minute) }

    @Test func holdsPowerAndKeepAliveWhileArmed() {
        let controller = makeController(since: date(6))
        controller.tick(now: date(6, 30))
        #expect(fakes.power.isHoldingSystemAwake)
        #expect(fakes.keepAlive.starts.map(\.0) == [alarmJBL.uid])
        #expect(controller.devices.speakerStatus == SpeakerStatus(bluetoothConnected: true, outputAvailable: true, keepAliveRunning: true))

        // Unchanged settings don't restart it; a new level does.
        controller.tick(now: date(6, 31))
        #expect(fakes.keepAlive.starts.count == 1)
        host.settings.alarm.speaker.keepAliveLevel = -50
        controller.tick(now: date(6, 32))
        #expect(fakes.keepAlive.starts.last?.1 == -50)

        host.settings.alarm.enabled = false
        controller.tick(now: date(6, 33))
        #expect(!fakes.power.isHoldingSystemAwake)
        #expect(!fakes.keepAlive.isRunning)
    }

    @Test func keepAliveStopsWhenTheSpeakerDisappears() {
        let controller = makeController(since: date(6))
        controller.tick(now: date(6, 30))
        fakes.outputs.list.withLock { $0.removeAll { $0 == alarmJBL } }
        controller.tick(now: date(6, 31))
        #expect(!fakes.keepAlive.isRunning)
        #expect(controller.devices.speakerStatus.outputAvailable == false)
        #expect(host.logs.last == "info: Keep-alive stopped: JBL Go 3 disconnected.")
    }

    @Test func keepAliveThatStoppedItselfIsStillLogged() {
        let controller = makeController(since: date(6))
        controller.tick(now: date(6, 30))
        fakes.keepAlive.stop()
        fakes.outputs.list.withLock { $0.removeAll { $0 == alarmJBL } }
        controller.tick(now: date(6, 31))
        #expect(host.logs.last == "info: Keep-alive stopped: JBL Go 3 disconnected.")
    }

    @Test func startsPrepInsideTheWindowOnce() {
        let controller = makeController(since: date(7))
        controller.tick(now: date(7, 50))
        #expect(controller.phase == .idle)
        #expect(controller.nextFireDate(for: host.settings.alarm, now: date(7, 50)) == date(8))

        controller.tick(now: date(7, 58))
        #expect(controller.phase == .preparing(scheduledFor: date(8)))
        #expect(controller.handledFireDate == date(8))
        #expect(controller.nextFireDate(for: host.settings.alarm, now: date(7, 58)) == date(8))
        controller.tick(now: date(7, 59))
        #expect(controller.phase == .preparing(scheduledFor: date(8)))
        controller.stop()
    }

    @Test func lateWakeRecordsASkippedAlarm() {
        let controller = makeController(since: date(7))
        controller.tick(now: date(9))
        #expect(controller.phase == .idle)
        #expect(host.runs.map(\.outcome) == [.skippedLate])
        #expect(host.runs.first?.scheduledFor == date(8))
        #expect(host.logs.contains { $0.hasPrefix("warning: Alarm: skipped the") })
        // Not skipped (or run) again.
        controller.tick(now: date(9, 1))
        #expect(host.runs.count == 1)
    }

    @Test func editedTimeAbandonsPrep() {
        let controller = makeController(since: date(7))
        controller.tick(now: date(7, 58))
        #expect(controller.phase == .preparing(scheduledFor: date(8)))

        host.settings.alarm.time = AlarmTime(hour: 7, minute: 59)
        controller.tick(now: date(7, 58))
        #expect(controller.phase == .preparing(scheduledFor: date(7, 59)))
        host.settings.alarm.time = AlarmTime(hour: 10, minute: 0)
        controller.tick(now: date(7, 58))
        #expect(controller.phase == .idle)
        #expect(controller.nextFireDate(for: host.settings.alarm, now: date(7, 58)) == date(10))
    }

    @Test func scheduledAlarmReplacesARunningTest() async {
        let controller = makeController(since: date(7))
        controller.testNow()
        controller.tick(now: date(7, 58))
        #expect(controller.phase == .preparing(scheduledFor: date(8)))
        #expect(controller.handledFireDate == date(8))
        controller.stop()
    }

    @Test func testRunIgnoresTheSchedule() async {
        let controller = makeController(since: date(7))
        controller.testNow()
        #expect(controller.phase.isActive)
        controller.testNow()
        let ended = await AlarmWaiting.poll(within: .seconds(5)) { controller.phase == .idle }
        #expect(ended)
        // Nothing to play in the empty Inbox, so the alarm sound played instead.
        #expect(host.runs.map(\.trigger) == [.test])
        #expect(host.runs.last?.outcome == .alarmSound)
    }
}
