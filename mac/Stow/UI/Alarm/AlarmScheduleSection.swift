import SwiftUI

/// Time and weekdays.
struct AlarmScheduleSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Schedule") {
            Committed(model.alarmSettings.time, commit: { time in model.updateAlarmSettings { $0.time = time } }) { time, _ in
                DatePicker("Time", selection: dateBinding(time), displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField)
            }
            FormRow("Days") {
                WeekdayPicker(selection: model.alarmSettings.days) { day in
                    model.updateAlarmSettings { $0.days = AlarmText.toggling(day, in: $0.days) }
                }
            }
        }
    }

    /// The picker edits a date; only its hour and minute matter.
    private func dateBinding(_ time: Binding<AlarmTime>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: time.wrappedValue.hour, minute: time.wrappedValue.minute,
                                  second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            time.wrappedValue = AlarmTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
    }
}

/// M T W T F S S as round toggle buttons.
struct WeekdayPicker: View {
    let selection: [Weekday]
    let toggle: (Weekday) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Weekday.allCases, id: \.self) { day in
                let isOn = selection.contains(day)
                Button { toggle(day) } label: {
                    Text(AlarmText.letter(day))
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(isOn ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(AlarmText.name(day))
                .accessibilityLabel(AlarmText.name(day))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// How many videos, in which order, how long, how loud.
struct AlarmPlaybackSection: View {
    @Environment(AppModel.self) private var model
    @State private var isTestingSound = false

    var body: some View {
        let settings = model.alarmSettings
        Section {
            Committed(settings.maxVideos, commit: { n in model.updateAlarmSettings { $0.maxVideos = n } }) { count, editing in
                FormRow("Videos per alarm") {
                    StepperValue(text: "\(count.wrappedValue)") {
                        Stepper("Videos per alarm", value: count, in: AlarmSettings.maxVideosRange, onEditingChanged: editing)
                    }
                }
            }
            Picker("Order", selection: Binding(
                get: { settings.order },
                set: { order in model.updateAlarmSettings { $0.order = order } }
            )) {
                Text("Oldest first").tag(AlarmOrder.oldestFirst)
                Text("Newest first").tag(AlarmOrder.newestFirst)
            }
            Committed(settings.maxDurationMinutes, commit: { n in model.updateAlarmSettings { $0.maxDurationMinutes = n } }) { minutes, editing in
                FormRow("Skip videos longer than") {
                    StepperValue(text: "\(minutes.wrappedValue) min") {
                        Stepper("Skip videos longer than", value: minutes, in: AlarmSettings.maxDurationRange, step: 5,
                                onEditingChanged: editing)
                    }
                }
            }
            Committed(Double(settings.volume), commit: { v in model.updateAlarmSettings { $0.volume = Int(v.rounded()) } }) { volume, editing in
                FormRow("Volume") {
                    HStack(spacing: 12) {
                        Slider(value: volume, in: 0...100,
                            label: { Text("Volume") },
                            minimumValueLabel: { Image(systemName: "speaker.fill").foregroundStyle(.secondary) },
                            maximumValueLabel: { Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary) },
                            onEditingChanged: editing)
                        .labelsHidden()
                        .frame(width: 260)
                        Text("\(Int(volume.wrappedValue.rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                        TestButton(title: "Test Sound", isRunning: isTestingSound, action: testSound)
                            .help("Plays the alarm sound for 2 seconds at this volume")
                    }
                }
            }
        } header: {
            Text("Videos")
        } footer: {
            Text("The alarm's speaker is set to this volume while the alarm plays, then put back.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func testSound() {
        isTestingSound = true
        Task {
            await model.testAlarmSound()
            isTestingSound = false
        }
    }
}
