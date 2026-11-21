import SwiftUI

/// The sections in the sidebar.
enum SidebarItem: String, CaseIterable, Identifiable {
    case inbox, channels, alarm, phone, account, log

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .channels: "Channels"
        case .alarm: "Alarm"
        case .phone: "Phone"
        case .account: "Account"
        case .log: "Log"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray.full"
        case .channels: "person.2"
        case .alarm: "alarm"
        case .phone: "iphone"
        case .account: "person.crop.circle"
        case .log: "doc.text"
        }
    }
}

/// The main window: a sidebar of sections and the selected section's content, with the player
/// panel beside it while a video plays (or filling it, expanded).
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
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    detail
                        .frame(maxWidth: dock.isExpanded && dock.screen != nil ? 0 : .infinity)
                        .opacity(dock.isExpanded && dock.screen != nil ? 0 : 1)
                    if let screen = dock.screen {
                        if !dock.isExpanded { Divider() }
                        PlayerPanel(dock: dock, screen: screen)
                            // Below the toolbar, like the section beside it.
                            .padding(.top, dock.isExpanded ? 0 : proxy.safeAreaInsets.top)
                            .frame(width: dock.isExpanded ? proxy.size.width : Self.panelWidth(in: proxy.size.width))
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .animation(.snappy(duration: 0.3), value: dock.screen == nil)
            .animation(.snappy(duration: 0.3), value: dock.isExpanded)
            .navigationTitle(selection.title)
            .toolbar { toolbar }
        }
        // Closing the main window stops the video playing in it.
        .onDisappear { dock.stop() }
    }

    private var dock: PlayerDock { PlayerDock.shared }

    /// About two fifths of the window, within reason.
    private static func panelWidth(in width: CGFloat) -> CGFloat {
        min(max(width * 0.42, 420), 820)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .inbox: InboxView()
        case .channels: ChannelsTab()
        case .alarm: AlarmTab()
        case .phone: PhoneTab()
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
