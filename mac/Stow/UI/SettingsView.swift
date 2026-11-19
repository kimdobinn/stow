import SwiftUI

/// The Settings window: Channels, Account, Alarm, Log tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Channels", systemImage: "list.bullet") { ChannelsTab() }
            Tab("Account", systemImage: "person.crop.circle") { AccountTab() }
            Tab("Alarm", systemImage: "alarm") { AlarmTab() }
            Tab("Log", systemImage: "doc.text") { LogTab() }
        }
        .frame(minWidth: 640, idealWidth: 640, minHeight: 480, idealHeight: 480)
    }
}

#if DEBUG
#Preview {
    SettingsView().environment(AppModel.preview)
}
#endif
