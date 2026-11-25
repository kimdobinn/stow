import SwiftUI

/// How the last alarm went.
struct LastAlarmSection: View {
    @Environment(AppModel.self) private var model
    let run: AlarmRunRecord

    var body: some View {
        Section("Last Alarm") {
            HStack(alignment: .top, spacing: 14) {
                AlarmIcon(systemImage: icon, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AlarmText.outcomeTitle(run))
                        .font(.body.weight(.semibold))
                    Text(AlarmText.runDetail(run))
                        .foregroundStyle(.secondary)
                    if let error = run.error, run.outcome != .stopped {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .noDragScroll()
                    }
                    if let rule = run.fallbackRule {
                        Text("Picked by fallback rule: \(AlarmText.kindTitle(rule.kind).lowercased())")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            ForEach(run.videoIds, id: \.self) { id in
                Label(title(of: id), systemImage: "play.rectangle")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Played videos have left the Inbox, so look in Recent too; an id that's gone is shown as is.
    private func title(of id: String) -> String {
        let video = model.recentVideos.first { $0.id == id } ?? model.inbox.first { $0.id == id }?.video
        return video.map { "\($0.title) · \($0.channelTitle)" } ?? id
    }

    private var icon: String {
        switch run.outcome {
        case .running: "play.fill"
        case .played: "checkmark"
        case .alarmSound: "bell.fill"
        case .skippedLate: "moon.zzz.fill"
        case .stopped: "stop.fill"
        case .failed: "exclamationmark"
        }
    }

    private var tint: Color {
        switch run.outcome {
        case .running: .blue
        case .played: .green
        case .alarmSound, .skippedLate: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

/// "Test Alarm Now…" with a confirmation, because it plays loudly.
struct TestAlarmSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirms = false

    var body: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Test the alarm")
                    Text("Runs the whole alarm now: refreshes feeds, then plays fullscreen at \(model.alarmSettings.volume)% volume.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Test Alarm Now…") { confirms = true }
                    .disabled(model.isAlarmRunning)
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog("Play the alarm now?", isPresented: $confirms) {
            Button("Play Now") { model.testAlarmNow() }
        } message: {
            Text("It plays fullscreen at \(model.alarmSettings.volume)% volume on \(outputName). "
                 + "Press Q in the player to stop. Videos you don't finish stay in the Inbox.")
        }
    }

    private var outputName: String {
        AlarmRunner.preferredOutput(for: model.alarmSettings, in: model.audioOutputs)?.name ?? "the default output"
    }
}
