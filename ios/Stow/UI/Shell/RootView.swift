import StowKit
import SwiftUI

/// Not paired: the pair screen. Paired (or in demo mode): the app. When the Mac unpairs this
/// phone, the repository says so and the pair screen comes back with the reason.
struct RootView: View {
    @Environment(Repository.self) private var repository

    var body: some View {
        Group {
            if repository.pairState == .paired {
                MainView()
            } else {
                PairScreen()
            }
        }
        .animation(.default, value: repository.pairState == .paired)
        .stowTheme(repository.prefs, avatars: repository.avatars)
        .onChange(of: repository.prefs.theme, initial: true) { _, theme in
            WindowStyle.apply(theme)
        }
    }
}

/// The tabs, each with its own navigation stack, and what any screen can bring up.
struct MainView: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell

    var body: some View {
        @Bindable var shell = shell
        TabView(selection: Binding(get: { shell.tab }, set: { shell.select($0) })) {
            NavigationStack(path: $shell.homePath) {
                HomeScreen().stowRoutes()
            }
            .miniPlayerInset()
            .toastHost()
            .tabItem { Label("Home", systemImage: "house") }
            .tag(AppTab.home)

            NavigationStack(path: $shell.subscriptionsPath) {
                SubscriptionsScreen().stowRoutes()
            }
            .miniPlayerInset()
            .toastHost()
            .tabItem { Label("Subscriptions", systemImage: "play.square.stack") }
            .tag(AppTab.subscriptions)

            NavigationStack(path: $shell.downloadsPath) {
                DownloadsScreen().stowRoutes()
            }
            .miniPlayerInset()
            .toastHost()
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            .tag(AppTab.downloads)
        }
        .sheet(item: $shell.grouping) { channel in
            GroupPickerSheet(channel: channel).sheetTheme(repository)
        }
        .sheet(item: $shell.saving) { item in
            SaveToPlaylistSheet(item: item).sheetTheme(repository)
        }
        // The watch page and mini player (UI/Player), over the tabs so the sheets above still show.
        .playerHost()
        .nameAlert("New group", isPresented: $shell.namingNewGroup, confirm: "Create") { name in
            let group = shell.groupActions.create(name)
            shell.open(.group(group.id))
        }
        .modifier(DownloadSizeAlert())
    }
}

/// Where each route goes. Screens other agents build are in their own folders.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .channel(let id): ChannelScreen(channelId: id)
        case .channels: ChannelsScreen()
        case .groups: GroupsScreen()
        case .group(let id): GroupScreen(groupId: id)
        case .playlist(let id): PlaylistScreen(playlistId: id)
        case .search: SearchScreen()
        case .settings: SettingsScreen()
        case .report: ReportScreen()
        case .ytdlp: YtDlpDebugView()
        }
    }
}

extension View {
    /// The app's routes on this navigation stack.
    func stowRoutes() -> some View {
        coveredByPlayer()
            .navigationDestination(for: Route.self) { RouteView(route: $0).coveredByPlayer() }
    }

    /// Out of VoiceOver's reach while the watch page covers it. Set on each screen: the modifier
    /// doesn't reach through the tab and navigation controllers from outside.
    func coveredByPlayer() -> some View {
        modifier(CoveredByPlayer())
    }

    /// The theme in a sheet or cover, which doesn't inherit the app's modifiers.
    func sheetTheme(_ repository: Repository) -> some View {
        stowTheme(repository.prefs, avatars: repository.avatars)
    }

    /// Shows the shell's short messages at the bottom, above the tab bar.
    func toastHost() -> some View {
        modifier(ToastHost())
    }
}

private struct CoveredByPlayer: ViewModifier {
    @Environment(Shell.self) private var shell

    func body(content: Content) -> some View {
        content.accessibilityHidden(shell.playback != nil && shell.playerExpanded)
    }
}

private struct ToastHost: ViewModifier {
    @Environment(Shell.self) private var shell

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = shell.toast {
                ToastView(message: toast.message)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The toolbar of a tab's first screen: search and settings, as on Android.
struct TabToolbar: ToolbarContent {
    let shell: Shell
    @Environment(\.stowColors) private var colors

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Search", systemImage: "magnifyingglass") { shell.open(.search) }
                .tint(colors.text)
            Button("Settings", systemImage: "gearshape") { shell.open(.settings) }
                .tint(colors.text)
        }
    }
}

/// Long streams can be several gigabytes: the size first, then download or not.
private struct DownloadSizeAlert: ViewModifier {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell

    func body(content: Content) -> some View {
        @Bindable var shell = shell
        content.sheet(item: $shell.sizing) { item in
            DownloadSizeSheet(item: item).sheetTheme(repository)
        }
    }
}

private struct DownloadSizeSheet: View {
    let item: VideoItem
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var size: Int64?
    @State private var checking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Download \(Format.duration(ms: item.durationMs)) video?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(colors.text)
            Text(item.video.title)
                .font(.body.weight(.medium))
                .foregroundStyle(colors.text)
                .lineLimit(2)
            HStack(spacing: 8) {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking the size…")
                } else {
                    Text(sizeText)
                }
            }
            .font(.subheadline)
            .foregroundStyle(colors.secondaryText)
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    dismiss()
                    repository.download(item)
                    shell.notify("Downloading")
                } label: {
                    Text("Download").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.top, 16)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(230)])
        .presentationBackground(colors.raised)
        .task {
            size = await repository.downloadSize(item)
            checking = false
        }
    }

    /// yt-dlp's figure; the repository falls back to an estimate from the length.
    private var sizeText: String {
        let quality = "up to \(repository.prefs.downloadQuality.label)"
        guard let size else { return "Size unknown (\(quality))" }
        return "Size: \(Format.bytes(size)) (\(quality))"
    }
}
