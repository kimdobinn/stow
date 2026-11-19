import Foundation
import Observation

/// Audio outputs, the Bluetooth speaker and its keep-alive signal, as the Alarm section shows them.
@MainActor
@Observable
final class AlarmDevices {
    private(set) var outputs: [AudioOutput] = []
    private(set) var bluetoothDevices: [BluetoothAudioDevice] = []
    private(set) var speakerStatus: SpeakerStatus = .unknown

    @ObservationIgnored var log: (LogLevel, String) -> Void = { _, _ in }
    @ObservationIgnored private let services: AlarmServices
    /// The level the keep-alive was last started with; nil once it is known to be stopped.
    @ObservationIgnored private var keepAliveLevel: Double?
    /// The last keep-alive error logged, so a retry every tick doesn't flood the log.
    @ObservationIgnored private var keepAliveIssue: String?

    init(services: AlarmServices) {
        self.services = services
    }

    /// Re-reads the devices and, when `manageKeepAlive` (once the alarm has started), starts,
    /// moves or stops the keep-alive to match `settings`.
    func refresh(_ settings: AlarmSettings, manageKeepAlive: Bool) {
        let outputs = services.outputs.outputs()
        if outputs != self.outputs { self.outputs = outputs }
        let devices = services.speaker.pairedAudioDevices()
        if devices != bluetoothDevices { bluetoothDevices = devices }
        let speakerOutput = AudioOutput.matching(settings.speaker, in: outputs)
        if manageKeepAlive { updateKeepAlive(settings, output: speakerOutput) }
        let status = SpeakerStatus(
            bluetoothConnected: settings.speaker.address.map { services.speaker.isConnected(address: $0) } ?? false,
            outputAvailable: speakerOutput != nil,
            keepAliveRunning: services.keepAlive.isRunning)
        if status != speakerStatus { speakerStatus = status }
    }

    private func updateKeepAlive(_ settings: AlarmSettings, output: AudioOutput?) {
        let keepAlive = services.keepAlive
        let level = settings.speaker.keepAliveLevel
        guard settings.enabled, !settings.days.isEmpty, settings.speaker.keepAlive, let output else {
            // Also logged when the keep-alive already stopped itself because the speaker went away.
            if keepAlive.isRunning || keepAliveLevel != nil {
                keepAlive.stop()
                log(.info, "Keep-alive stopped" + (output == nil ? ": \(settings.speaker.name) disconnected." : "."))
            }
            keepAliveLevel = nil
            return
        }
        guard !keepAlive.isRunning || keepAlive.deviceUID != output.uid || keepAliveLevel != level else { return }
        do {
            try keepAlive.start(deviceUID: output.uid, levelDBFS: level)
            keepAliveLevel = level
            keepAliveIssue = nil
            log(.info, "Keep-alive playing on \(output.name) at \(Int(level)) dBFS.")
        } catch {
            let issue = error.logDescription
            if issue != keepAliveIssue { log(.warning, "Keep-alive couldn't start on \(output.name): \(issue)") }
            keepAliveIssue = issue
        }
    }

    func connect(_ speaker: SpeakerSettings) async -> Bool {
        guard let address = speaker.address else {
            log(.warning, "\(speaker.name) has no Bluetooth address to connect to.")
            return false
        }
        log(.info, "Connecting \(speaker.name)…")
        let connected = await services.speaker.connect(address: address, timeout: AlarmRunner.connectTimeout)
        log(connected ? .info : .warning,
            connected ? "Connected \(speaker.name)." : "Couldn't connect \(speaker.name) (off or out of range?).")
        return connected
    }

    /// Plays the keep-alive signal at the configured level for a few seconds.
    func testKeepAlive(_ speaker: SpeakerSettings, duration: Duration) async {
        guard let output = AudioOutput.matching(speaker, in: services.outputs.outputs()) else {
            return log(.warning, "Keep-alive test: \(speaker.name) isn't connected.")
        }
        do {
            try await services.keepAlive.test(deviceUID: output.uid, levelDBFS: speaker.keepAliveLevel, duration: duration)
        } catch {
            log(.warning, "Keep-alive test failed on \(output.name): \(error.logDescription)")
        }
    }

    /// Plays the alarm sound at the alarm volume on the output the alarm would use now, then puts
    /// that output's volume back.
    func testSound(_ settings: AlarmSettings, duration: Duration) async {
        let output = AlarmRunner.preferredOutput(for: settings, in: services.outputs.outputs())
        let outputs = services.outputs
        let previous = output.flatMap { outputs.volume(deviceUID: $0.uid) }
        defer { if let output, let previous { try? outputs.setVolume(previous, deviceUID: output.uid) } }
        do {
            if let output { try outputs.setVolume(Double(settings.volume) / 100, deviceUID: output.uid) }
            try await services.sound.play(deviceUID: output?.uid, duration: duration)
        } catch {
            log(.warning, "Test sound failed on \(output?.name ?? "the system default output"): \(error.logDescription)")
        }
    }
}
