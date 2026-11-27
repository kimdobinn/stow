#if DEBUG
import AppKit
import SwiftUI

/// `Stow --snapshot <dir>` (Debug builds only): renders every section of the main window
/// to PNGs, using a temporary copy of the real settings and state so nothing real is changed.
@MainActor
enum Snapshot {
    static let argument = "--snapshot"

    static func run() async -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: argument), args.indices.contains(index + 1) else {
            print("usage: Stow --snapshot <output directory>")
            return false
        }
        let output = URL(filePath: args[index + 1], directoryHint: .isDirectory)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "stow-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let model = try makeModel(in: scratch)
            await model.signIn()
            // Shows the watched look on a couple of Recent videos (temporary store only).
            for video in model.recentVideos.prefix(2) { model.setWatched(true, videoId: video.id) }
            NSApplication.shared.setActivationPolicy(.prohibited)

            let screens: [Screen] = SidebarItem.allCases.map { item in
                Screen(name: item.rawValue, view: AnyView(MainView(selection: item).frame(width: 1180, height: 760)))
            } + [
                Screen(name: "subscriptions", view: AnyView(SubscriptionsPicker())),
                // The whole Alarm form, which scrolls in the window.
                Screen(name: "alarm-full", view: AnyView(AlarmTab().frame(width: 980, height: 1900))),
                Screen(name: "alarm-running", view: AnyView(MainView(selection: .alarm).frame(width: 1180, height: 760)),
                       phase: samplePlayingPhase(model)),
            ] + playbackScreens(model)
                + playerPanelScreens(model)
            let passes: [(NSAppearance.Name, String, AppTheme)] = [(.aqua, "light", .system), (.darkAqua, "dark", .system),
                                                                   (.aqua, "paper", .paper)]
            // The Account section shows an update on offer, with its notes.
            let updater = AppUpdater.preview(status: .available(AppUpdater.sampleRelease))
            let ytdlp = YtDlpUpdater.preview(version: DottedVersion("2026.11.23"))
            for (appearance, suffix, theme) in passes {
                for screen in screens {
                    model.previewAlarmPhase(screen.phase)
                    PlayerDock.shared.showPreview(screen.player)
                    if let videoId = screen.comments {
                        CommentsLoader.shared.load(videoId: videoId, cookiesFile: nil)
                        await CommentsLoader.shared.settle()
                    }
                    let url = output.appending(path: "\(screen.name)-\(suffix).png")
                    if let size = screen.windowSize {
                        try await renderWindow(screen.view.environment(model).environment(updater).environment(ytdlp)
                            .environment(\.appTheme, theme), size: size, appearance: appearance, to: url)
                    } else {
                        try await render(screen.view.environment(model).environment(updater).environment(ytdlp)
                            .environment(\.appTheme, theme), appearance: appearance, to: url)
                    }
                    print(url.path)
                }
                PlayerDock.shared.showPreview(nil)
            }
            model.previewAlarmPhase(.idle)
            return true
        } catch {
            print("Snapshot failed: \(error)")
            return false
        }
    }

    private static func makeModel(in directory: URL) throws -> AppModel {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if CommandLine.arguments.contains(SnapshotDemo.argument) {
            try SnapshotDemo.write(to: Store(directory: directory))
        } else {
            for file in [AppPaths.settingsFile, AppPaths.stateFile, AppPaths.logFile]
            where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.copyItem(at: file, to: directory.appending(path: file.lastPathComponent))
            }
        }
        let model = AppModel(youtube: YouTubeClient(), account: SnapshotAccount(),
                             store: Store(directory: directory), notifier: SilentNotifier(),
                             cookiesFile: directory.appending(path: "cookies.txt"), alarmServices: .sample)
        model.load()
        addSampleAlarmRun(to: model)
        return model
    }

    private struct Screen {
        var name: String
        var view: AnyView
        var phase: AlarmPhase = .idle
        /// Shown in the player panel beside the section.
        var player: PlaybackScreen?
        /// Opens the comments column on this video (fetched for real).
        var comments: String? = nil
        /// Rendered in a real window of this size (with its toolbar) instead of on its own.
        var windowSize: CGSize?
    }

    /// The Inbox with the player panel beside it (no video, so the video area is black), in a
    /// real window so the toolbar above the panel shows, at a typical and a wide window size.
    private static func playerPanelScreens(_ model: AppModel) -> [Screen] {
        guard let video = model.inbox.first?.video ?? model.recentVideos.first else { return [] }
        let nowPlaying = NowPlaying(index: 0, count: 1, video: video, isLoading: false, isPaused: false,
                                    position: 130, duration: 870, upNext: nil)
        let player = PlaybackScreen(mode: .watch, nowPlaying: nowPlaying, showsChrome: true) { _ in }
        return [CGSize(width: 1280, height: 800), CGSize(width: 1900, height: 900)].map { size in
            Screen(name: "inbox-player-\(Int(size.width))", view: AnyView(MainView(selection: .inbox)),
                   player: player, windowSize: size)
        } + [Screen(name: "comments", view: AnyView(CommentsView(videoId: video.id).frame(width: 360, height: 820)),
                    comments: video.id)]
    }

    /// A finished test run of two recent videos, so "Last Alarm" shows up (temporary store only).
    private static func addSampleAlarmRun(to model: AppModel) {
        guard model.lastAlarmRun == nil else { return }
        let start = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
        let run = AlarmRunRecord(trigger: .test, scheduledFor: start, startedAt: start,
                                 endedAt: start.addingTimeInterval(24 * 60),
                                 videoIds: model.recentVideos.prefix(2).map(\.id),
                                 output: "JBL Go 3", outcome: .played)
        model.recordAlarmRun(run, watchedIds: [])
    }

    private static func samplePlayingPhase(_ model: AppModel) -> AlarmPhase {
        let video = model.inbox.first?.video ?? model.recentVideos.first ?? InboxItem.preview.video
        return .playing(index: 0, count: 3, video: video)
    }

    /// The alarm's fullscreen controls over a video thumbnail, at the first screen's size.
    private static func playbackScreens(_ model: AppModel) -> [Screen] {
        let videos = Array((model.inbox.map(\.video) + model.recentVideos).prefix(3))
        guard videos.count == 3 else { return [] }
        let size = NSScreen.screens.first?.frame.size ?? CGSize(width: 1920, height: 1080)
        let image = URL(string: "https://i.ytimg.com/vi/\(videos[0].id)/maxresdefault.jpg").flatMap(NSImage.init(contentsOf:))
        func screen(_ name: String, _ nowPlaying: NowPlaying) -> Screen {
            let state = PlaybackScreen(nowPlaying: nowPlaying, showsChrome: true) { _ in }
            let view = AlarmPlaybackView(screen: state)
                .background {
                    if let image, !nowPlaying.isLoading {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .background(.black)
                .frame(width: size.width, height: size.height)
            return Screen(name: name, view: AnyView(view))
        }
        let playing = NowPlaying(index: 0, count: 3, video: videos[0], isLoading: false, isPaused: false,
                                 position: 130, duration: 870, upNext: videos[1])
        var paused = playing
        paused.isPaused = true
        var loading = playing
        loading.isLoading = true
        return [screen("playback-playing", playing), screen("playback-paused", paused),
                screen("playback-loading", loading)]
    }

    /// Renders `view` as the content of a titled window, toolbar included.
    private static func renderWindow(_ view: some View, size: CGSize, appearance: NSAppearance.Name,
                                     to url: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(3))
        defer { window.orderOut(nil) }
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) async throws {
        let host = NSHostingView(rootView: view.background(.background))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.orderFrontRegardless()
        // Let AsyncImage thumbnails and avatars load.
        try await Task.sleep(for: .seconds(3))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Signed in, with a few subscriptions for the picker; never touches the real web data store.
@MainActor
private final class SnapshotAccount: AccountService {
    func refresh() async -> SignInState { .signedIn }
    func signIn() async -> Bool { true }
    func signOut() async {}
    func fetchSubscriptions() async throws -> [ChannelInfo] {
        [
            ChannelInfo(id: "UC-XMoeMXbYrMlvmyLSwDd3g", title: "Jack Hopkins", handle: "@JackhopkinsCEO"),
            ChannelInfo(id: "UCeUP5Kb-EDDplwAi0H02XlA", title: "TQQQ미친놈", handle: "@TQQQCRAZY"),
            ChannelInfo(id: "UCHnyfMqiRRG1u-2MsSQLbXA", title: "Veritasium", handle: "@veritasium"),
        ]
    }
}
#endif
