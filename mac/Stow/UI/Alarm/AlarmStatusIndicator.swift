import SwiftUI

/// Toolbar status while the alarm is active (preparing, playing or ringing), with Stop.
/// Shows nothing when the alarm is idle.
struct AlarmStatusIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isAlarmRunning {
            let phase = model.alarmPhase
            HStack(spacing: 6) {
                Image(systemName: phase.systemImage)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                Text(AlarmText.shortPhase(phase))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Button("Stop", systemImage: "stop.fill") { model.stopAlarm() }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(StopButtonStyle(font: .caption.weight(.semibold),
                                                 padding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)))
                    .help("Stop the alarm (⌘.)")
            }
            .help(AlarmText.phaseDetail(phase) ?? AlarmText.phaseTitle(phase))
        }
    }
}
