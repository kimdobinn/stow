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
    /// The player panel's width as last dragged; 0 until then (an automatic width).
    @AppStorage("playerPanelWidth") private var preferredPanelWidth: Double = 0
    /// The width when a drag of the panel's edge began.
    @State private var dragStartWidth: CGFloat?
    /// The height of the title and buttons under the video.
    @State private var panelDetailsHeight: CGFloat = 130
    /// The space for the section and the panel, below the toolbar.
    @State private var detailSize = CGSize(width: 1000, height: 700)

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
            let range = panelWidthRange(in: detailSize)
            let panelWidth = currentPanelWidth(range: range)
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: dock.isExpanded && dock.screen != nil ? 0 : .infinity)
                    .opacity(dock.isExpanded && dock.screen != nil ? 0 : 1)
                if let screen = dock.screen {
                    if !dock.isExpanded { resizeHandle(width: panelWidth, range: range) }
                    // Laid out in the safe area, so it starts right under the toolbar.
                    PlayerPanel(dock: dock, screen: screen) { panelDetailsHeight = $0 }
                        .frame(width: dock.isExpanded ? detailSize.width : panelWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                detailSize = $0
                dock.detailWidth = $0.width
            }
            .onChange(of: plannedPanelWidth, initial: true) { dock.plannedPanelWidth = $1 }
            .background(WindowReader { dock.hostWindow = $0 })
            .animation(.snappy(duration: 0.3), value: dock.screen == nil)
            .animation(.snappy(duration: 0.3), value: dock.isExpanded)
            .navigationTitle(selection.title)
            .toolbar { toolbar }
        }
        // Closing the main window stops the video playing in it.
        .onDisappear { dock.stop() }
    }

    private var dock: PlayerDock { PlayerDock.shared }

    private static let minPanelWidth: CGFloat = 420
    /// What the panel always leaves of the section beside it.
    private static let minSectionWidth: CGFloat = 320

    /// The panel's widths: at most as wide as lets the video and the details under it fill the
    /// height (wider would only push them off the bottom), and leaving room for the section.
    private func panelWidthRange(in size: CGSize) -> ClosedRange<CGFloat> {
        let fillsHeight = (size.height - panelDetailsHeight) * 16 / 9
        let upper = min(size.width - Self.minSectionWidth, fillsHeight)
        return Self.minPanelWidth...max(Self.minPanelWidth, upper)
    }

    /// The video and the details under it fill the height at this width.
    private var fillsHeightWidth: CGFloat { (detailSize.height - panelDetailsHeight) * 16 / 9 }

    /// How wide the panel is when it opens (the window grows by this much).
    private var plannedPanelWidth: CGFloat {
        max(preferredPanelWidth > 0 ? preferredPanelWidth : fillsHeightWidth, Self.minPanelWidth)
    }

    /// When the window grew for the panel, the section keeps its width and the panel takes the
    /// rest; otherwise the panel takes its share of the window.
    private func currentPanelWidth(range: ClosedRange<CGFloat>) -> CGFloat {
        if let kept = keptSectionWidth(in: detailSize.width) {
            return max(detailSize.width - kept - 1, 0)
        }
        return Self.clamp(preferredPanelWidth > 0 ? preferredPanelWidth : fillsHeightWidth, to: range)
    }

    /// The section's width beside the panel, when the window grew for it. While the window
    /// resizes it stays exactly as it was; after that it gives way to keep the panel usable.
    private func keptSectionWidth(in width: CGFloat) -> CGFloat? {
        guard let kept = dock.keptSectionWidth else { return nil }
        if dock.isResizingWindow { return min(kept, width - 1) }
        return min(max(kept, Self.minSectionWidth), max(width - 1 - Self.minPanelWidth, Self.minSectionWidth))
    }

    private static func clamp(_ width: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(width, range.lowerBound), range.upperBound)
    }

    /// The line between the section and the panel: drag it to resize the panel, double-click it
    /// to go back to the automatic width.
    private func resizeHandle(width: CGFloat, range: ClosedRange<CGFloat>) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: .leading))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStartWidth ?? width
                                dragStartWidth = start
                                let panel = Self.clamp(start - drag.translation.width, to: range)
                                preferredPanelWidth = panel
                                if dock.keptSectionWidth != nil { dock.keptSectionWidth = detailSize.width - panel - 1 }
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    .onTapGesture(count: 2) {
                        preferredPanelWidth = 0
                        if dock.keptSectionWidth != nil {
                            dock.keptSectionWidth = detailSize.width - Self.clamp(fillsHeightWidth, to: range) - 1
                        }
                    }
                    .help("Drag to resize the player; double-click for the automatic size")
            }
            .zIndex(1)
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
