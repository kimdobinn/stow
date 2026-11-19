import Foundation

/// The alarm as the UI sees it. FROZEN API (signatures); the engine owns the bodies.
/// Settings themselves are `alarmSettings` / `updateAlarmSettings` / `lastAlarmRun` in AppModel.swift.
extension AppModel {
    /// Nil when the alarm is off or has no days.
    var nextAlarmDate: Date? { alarm.nextFireDate(for: alarmSettings) }

    var alarmPhase: AlarmPhase { alarm.phase }

    /// From prep until the run ends.
    var isAlarmRunning: Bool { alarm.phase.isActive }

    /// What the alarm would play right now (planner dry-run on the current state, no yt-dlp).
    var upNextPreview: AlarmPreview {
        let settings = alarmSettings
        var generator = SeededGenerator(day: nextAlarmDate ?? .now, calendar: alarm.calendar)
        return AlarmPlanner.preview(AlarmPlanner.rounds(settings: settings, channels: channels, state: currentState,
                                                        now: .now, using: &generator))
    }

    var speakerStatus: SpeakerStatus { alarm.devices.speakerStatus }

    /// CoreAudio outputs, for the fallback output picker and the speaker picker.
    var audioOutputs: [AudioOutput] { alarm.devices.outputs }

    /// Paired Bluetooth audio devices, for the speaker picker.
    var bluetoothAudioDevices: [BluetoothAudioDevice] { alarm.devices.bluetoothDevices }

    /// Re-reads outputs, paired devices and the speaker status (e.g. when the Alarm section appears).
    func refreshAudioDevices() { alarm.refreshDevices() }

    /// Connects the configured Bluetooth speaker (logs the result). Returns whether it is connected.
    func connectSpeaker() async -> Bool { await alarm.connectSpeaker() }

    /// Runs the whole alarm (prep, then play) now. The UI asks for confirmation first: it is loud.
    func testAlarmNow() { alarm.testNow() }

    /// Stops a running alarm (prep, mpv or the alarm sound). The run is recorded as it stands.
    func stopAlarm() { alarm.stop() }

    /// Plays the alarm sound for 2 s at `alarmSettings.volume` on the output the alarm would use.
    func testAlarmSound() async { await alarm.testSound() }

    /// Plays the keep-alive signal for a few seconds at the configured level on the speaker.
    func testKeepAlive() async { await alarm.testKeepAlive() }

    #if DEBUG
    /// Shows `phase` without running anything, for previews and `--snapshot`.
    func previewAlarmPhase(_ phase: AlarmPhase) { alarm.previewPhase(phase) }
    #endif
}
