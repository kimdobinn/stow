import SwiftUI

/// The Alarm section: schedule, videos, up next, speaker, fallback rules, last run, test and stop.
struct AlarmTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            AlarmHeader()
            AlarmScheduleSection()
            AlarmPlaybackSection()
            AlarmUpNextSection()
            AlarmSpeakerSection()
            FallbackRulesSection()
            if let run = model.lastAlarmRun {
                LastAlarmSection(run: run)
            }
            TestAlarmSection()
        }
        .formStyle(.grouped)
        .onAppear { model.refreshAudioDevices() }
    }
}

#if DEBUG
#Preview {
    AlarmTab()
        .environment(AppModel.preview)
        .frame(width: 900, height: 900)
}
#endif
