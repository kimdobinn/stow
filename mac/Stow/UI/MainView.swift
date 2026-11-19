import SwiftUI

/// The sections in the sidebar.
enum SidebarItem: String, CaseIterable, Identifiable {
    case inbox, channels, alarm, account, log

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .channels: "Channels"
        case .alarm: "Alarm"
        case .account: "Account"
        case .log: "Log"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray.full"
        case .channels: "person.2"
        case .alarm: "alarm"
        case .account: "person.crop.circle"
        case .log: "doc.text"
        }
    }
}

/// The main window: a sidebar of sections and the selected section's content.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem

    init(selection: SidebarItem = .inbox) {
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .badge(item == .inbox ? model.inbox.count : 0)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .navigationTitle(selection.title)
                .toolbar { toolbar }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .inbox: InboxView()
        case .channels: ChannelsTab()
        case .alarm: AlarmTab()
        case .account: AccountTab()
        case .log: LogTab()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            HStack(spacing: 10) {
                AlarmStatusIndicator()
                CheckStatusLine()
                SignInBadge(state: model.signInState)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.checkNow() }
            } label: {
                if model.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
            }
            .help("Check all channels for new videos (⌘R)")
            .disabled(model.isChecking)
        }
    }
}

#if DEBUG
#Preview {
    MainView().environment(AppModel.preview)
}
#endif
