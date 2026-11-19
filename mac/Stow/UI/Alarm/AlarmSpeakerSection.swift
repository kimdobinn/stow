import SwiftUI

/// The speaker the alarm plays on, keeping it awake, and the output used when it's missing.
struct AlarmSpeakerSection: View {
    @Environment(AppModel.self) private var model
    @State private var isConnecting = false
    @State private var isTestingKeepAlive = false

    var body: some View {
        let speaker = model.alarmSettings.speaker
        Section {
            Picker("Speaker", selection: speakerBinding) {
                ForEach(speakerChoices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            FormRow("Status") {
                HStack(spacing: 12) {
                    StatusDot(status: model.speakerStatus, isBluetooth: speaker.address != nil)
                    if speaker.address != nil, !model.speakerStatus.outputAvailable {
                        TestButton(title: "Connect", isRunning: isConnecting, action: connect)
                    }
                }
            }
            Toggle("Keep the speaker awake", isOn: Binding(
                get: { speaker.keepAlive },
                set: { on in model.updateAlarmSettings { $0.speaker.keepAlive = on } }
            ))
            Committed(speaker.keepAliveLevel, commit: { level in model.updateAlarmSettings { $0.speaker.keepAliveLevel = level.rounded() } }) { level, editing in
                FormRow("Keep-alive level") {
                    HStack(spacing: 12) {
                        Slider(value: level, in: SpeakerSettings.keepAliveLevelRange,
                            label: { Text("Keep-alive level") },
                            minimumValueLabel: { Text("Quiet").font(.caption).foregroundStyle(.secondary) },
                            maximumValueLabel: { Text("Loud").font(.caption).foregroundStyle(.secondary) },
                            onEditingChanged: editing)
                        .labelsHidden()
                        .frame(width: 260)
                        Text("\(Int(level.wrappedValue.rounded())) dB")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                        TestButton(title: "Test", isRunning: isTestingKeepAlive, action: testKeepAlive)
                            .help("Plays the keep-alive signal for a few seconds at this level")
                    }
                }
                .disabled(!speaker.keepAlive)
            }
            Picker("If it's not available, use", selection: Binding(
                get: { model.alarmSettings.fallbackOutput },
                set: { name in model.updateAlarmSettings { $0.fallbackOutput = name } }
            )) {
                ForEach(fallbackOutputNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        } header: {
            Text("Speaker")
        } footer: {
            Text("A near-silent signal stops the speaker from switching itself off between alarms. "
                 + "If its output is still missing at alarm time, the alarm plays on the fallback output, "
                 + "then the Mac's own speakers.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var speakerChoices: [SpeakerChoice] {
        AlarmText.speakerChoices(devices: model.bluetoothAudioDevices, outputs: model.audioOutputs,
                                 current: model.alarmSettings.speaker)
    }

    private var speakerBinding: Binding<String> {
        Binding {
            SpeakerChoice(name: model.alarmSettings.speaker.name, address: model.alarmSettings.speaker.address).id
        } set: { id in
            guard let choice = speakerChoices.first(where: { $0.id == id }) else { return }
            model.updateAlarmSettings {
                $0.speaker.name = choice.name
                $0.speaker.address = choice.address
            }
        }
    }

    /// Current outputs, plus the configured name when it isn't connected.
    private var fallbackOutputNames: [String] {
        let names = model.audioOutputs.map(\.name)
        let configured = model.alarmSettings.fallbackOutput
        return AudioOutput.named(configured, in: model.audioOutputs) == nil ? names + [configured] : names
    }

    private func connect() {
        isConnecting = true
        Task {
            _ = await model.connectSpeaker()
            isConnecting = false
        }
    }

    private func testKeepAlive() {
        isTestingKeepAlive = true
        Task {
            await model.testKeepAlive()
            isTestingKeepAlive = false
        }
    }
}

/// A colored dot and a few words: ready, connected without audio, or not connected.
private struct StatusDot: View {
    let status: SpeakerStatus
    let isBluetooth: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        if status.outputAvailable { return .green }
        return status.bluetoothConnected ? .yellow : .red
    }

    private var title: String {
        if status.outputAvailable { return status.keepAliveRunning ? "Ready · kept awake" : "Ready" }
        if status.bluetoothConnected { return "Connected, no audio output yet" }
        return isBluetooth ? "Not connected" : "Not available"
    }
}
