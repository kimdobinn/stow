import Foundation
import Testing
@testable import Stow

/// Only the paths that fail before anything plays; nothing here makes a sound.
@MainActor
struct AlarmSoundTests {
    @Test func defaultSoundExists() {
        #expect(FileManager.default.fileExists(atPath: AlarmSound.defaultSound.path))
    }

    @Test func unknownDeviceThrows() async {
        let sound = AlarmSound()
        await #expect(throws: StowError.audioDeviceNotFound("no-such-device")) {
            try await sound.play(deviceUID: "no-such-device", duration: .milliseconds(10))
        }
        #expect(!sound.isPlaying)
    }

    @Test func missingSoundThrows() async {
        let sound = AlarmSound(sound: URL(filePath: "/nonexistent/alarm.aiff"))
        await #expect(throws: StowError.audio("Alarm sound missing: /nonexistent/alarm.aiff")) {
            try await sound.play(deviceUID: "no-such-device", duration: .milliseconds(10))
        }
    }
}
