import os
import StowKit
import SwiftUI
import UIKit

/// What lives as long as the app: the repository (with yt-dlp plugged in), the shell, and the
/// background time downloads need.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let repository: Repository
    let shell: Shell
    let player: PlaybackController
    let backgroundDownloads: BackgroundDownloads
    /// Looks for a newer iPhone release on GitHub (Settings › About, the banner on Home).
    let updates: UpdateChecker
    private var started = false
    private let log = Logger(subsystem: "dev.stow.ios", category: "app")

    private init() {
        repository = Repository.live(youtube: YtDlpTool())
        repository.deviceName = UIDevice.current.name
        shell = Shell(repository: repository)
        player = PlaybackController(repository: repository)
        shell.player = player
        player.onExpand = { [weak shell] in shell?.playerExpanded = true }
        backgroundDownloads = BackgroundDownloads(repository: repository)
        updates = Self.makeUpdateChecker()
    }

    /// The installed version, and in debug builds `-updates-url <url>`: the releases list from
    /// there instead of GitHub (a fake one on the Mac, for the simulator), checked at every launch.
    private static func makeUpdateChecker(arguments: [String] = ProcessInfo.processInfo.arguments) -> UpdateChecker {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        #if DEBUG
        if let index = arguments.firstIndex(of: "-updates-url"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            let suite = "dev.stow.ios.updates-debug"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            return UpdateChecker(currentVersion: version, url: url, defaults: UserDefaults(suiteName: suite) ?? .standard)
        }
        #endif
        return UpdateChecker(currentVersion: version)
    }

    /// The daily update check, unless the app is hosting unit tests.
    func checkForUpdatesIfDue() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        await updates.checkIfDue()
    }

    /// Once, at launch.
    func start() {
        guard !started else { return }
        started = true
        repository.start()
        backgroundDownloads.requestQuietNotifications()
    }

    /// Polls while the app is on screen; asks iOS for a refresh (and time for downloads) when it leaves.
    func scenePhaseChanged(_ phase: ScenePhase) {
        repository.setActive(phase == .active)
        if phase == .active {
            backgroundDownloads.appBecameActive()
            Task { await checkForUpdatesIfDue() }
        }
        if phase == .background {
            BackgroundWork.scheduleRefresh()
            if !repository.downloads.queuedIds.isEmpty { BackgroundWork.scheduleDownloads() }
        }
    }

    /// stow://pair?… from the Camera app or a link.
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "stow", url.host?.lowercased() == "pair" else { return }
        Task { await repository.pair(url.absoluteString) }
    }

}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background task handlers must be registered before launch ends.
        BackgroundWork.register(AppServices.shared)
        AppServices.shared.start()
        return true
    }

    /// Portrait, except on the watch page, where turning the phone goes full screen.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.allowed
    }
}
