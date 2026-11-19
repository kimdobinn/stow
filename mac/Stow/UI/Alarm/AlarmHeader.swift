import SwiftUI

/// "Next alarm: Tomorrow 08:00" with the on/off switch, and the running alarm with Stop.
struct AlarmHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            HStack(spacing: 16) {
                AlarmIcon(systemImage: "alarm.fill", tint: model.alarmSettings.enabled ? .orange : .secondary)
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next alarm")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(title(now: context.date))
                            .font(.title.weight(.bold))
                            .foregroundStyle(model.nextAlarmDate == nil ? .secondary : .primary)
                        if let subtitle = subtitle(now: context.date) {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Toggle("Alarm", isOn: Binding(
                    get: { model.alarmSettings.enabled },
                    set: { on in model.updateAlarmSettings { $0.enabled = on } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
                .help(model.alarmSettings.enabled ? "Turn the alarm off" : "Turn the alarm on")
            }
            .padding(.vertical, 6)
            if model.isAlarmRunning {
                RunningAlarmRow()
            }
        }
    }

    private func title(now: Date) -> String {
        let settings = model.alarmSettings
        if !settings.enabled { return "Off" }
        if settings.days.isEmpty { return "No days selected" }
        guard let date = model.nextAlarmDate else { return settings.time.string }
        return AlarmText.nextAlarm(date, now: now)
    }

    private func subtitle(now: Date) -> String? {
        guard let date = model.nextAlarmDate, model.alarmSettings.enabled else {
            return model.alarmSettings.enabled ? nil : "Turn it on to play your morning videos."
        }
        let output = AlarmRunner.preferredOutput(for: model.alarmSettings, in: model.audioOutputs)?.name
        return [AlarmText.countdown(to: date, now: now), output.map { "on \($0)" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}

/// The alarm in progress, with a prominent Stop.
private struct RunningAlarmRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let phase = model.alarmPhase
        HStack(spacing: 16) {
            AlarmIcon(systemImage: phase.systemImage, tint: .red)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text(AlarmText.phaseTitle(phase))
                    .font(.title3.weight(.semibold))
                if let detail = AlarmText.phaseDetail(phase) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(role: .destructive) {
                model.stopAlarm()
            } label: {
                Label("Stop Alarm", systemImage: "stop.fill")
            }
            .buttonStyle(StopButtonStyle(font: .title3.weight(.semibold),
                                         padding: EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 6)
    }
}

extension AlarmPhase {
    var systemImage: String {
        switch self {
        case .idle: "alarm"
        case .preparing: "hourglass"
        case .starting: "play.circle"
        case .playing: "play.tv.fill"
        case .alarmSound: "bell.and.waves.left.and.right.fill"
        }
    }
}
