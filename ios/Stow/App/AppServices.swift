import os
import StowKit
import SwiftUI
import UIKit
import UserNotifications

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
        #if DEBUG
        Self.applyDebugMode()
        #endif
        repository = Repository.live(youtube: YtDlpTool())
        repository.deviceName = UIDevice.current.name
        repository.onYouTubeSignedOut = { Self.notifySignedOut() }
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
        #if DEBUG
        applyDebugStandalone()
        #endif
    }

    /// Standalone: YouTube stopped taking the phone's sign-in (once per time it happens).
    static func notifySignedOut() {
        let content = UNMutableNotificationContent()
        content.title = "YouTube signed you out of Stow"
        content.body = "Sign in again in Settings for Home, Subscriptions and members-only videos."
        let request = UNNotificationRequest(identifier: "dev.stow.ios.youtube-signed-out", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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

    /// stow://pair?… from the Camera app or a link. While Stow runs on its own, it asks first.
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "stow", url.host?.lowercased() == "pair" else { return }
        if repository.mode == .standalone {
            shell.pairingLink = url.absoluteString
            return
        }
        Task { await repository.pair(url.absoluteString) }
    }

    #if DEBUG
    /// Debug builds' launch arguments for standalone mode, read before the Repository is built:
    /// `-standalone` (or a file named "standalone" in Application Support) picks it unless paired,
    /// `-choose-mode` clears the mode unless paired, `-standalone-reset` deletes standalone.json and
    /// the Keychain cookies.
    private static func applyDebugMode(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let log = Logger(subsystem: "dev.stow.ios", category: "app")
        let prefs = Prefs()
        let paired = prefs.pairedProject != nil
        let directory = StowPaths.applicationSupport
        if arguments.contains("-standalone-reset") {
            StandaloneStore(directory: directory).delete()
            try? KeychainCookieVault().save(nil)
            log.info("-standalone-reset: standalone.json and the YouTube sign-in deleted")
        }
        if arguments.contains("-choose-mode"), !paired {
            prefs.appMode = nil
        }
        if Demo.wantsStandalone(arguments: arguments, directory: directory) {
            if Demo.isEnabled(arguments: arguments, directory: directory) {
                log.warning("-standalone ignored: demo mode wins")
            } else if paired {
                log.warning("-standalone ignored: paired")
            } else {
                prefs.appMode = AppMode.standalone.stored
            }
        }
    }

    /// After start: `-channels <ref>,<ref>` follows each (skipping followed ones) and checks;
    /// `-cookies <path>` imports a cookies.txt inside the app's container without verifying it.
    private func applyDebugStandalone(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let standalone = repository.standalone else { return }
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let path = value("-cookies") {
            // Relative to the app's data container, e.g. "Library/Application Support/test-cookies.txt".
            let url = path.hasPrefix("/") ? URL(filePath: path) : URL(filePath: NSHomeDirectory()).appending(path: path)
            Task {
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    try await standalone.signIn(cookies: text, source: .file, verify: false)
                    log.info("-cookies: imported \(url.lastPathComponent, privacy: .public)")
                } catch {
                    log.error("-cookies: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if let list = value("-channels") {
            let refs = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            Task {
                for ref in refs {
                    if ChannelResolver.isChannelId(ref), standalone.isFollowing(ref) { continue }
                    do {
                        let channel = try await standalone.addChannel(input: ref)
                        log.info("-channels: following \(channel.title, privacy: .public)")
                    } catch {
                        log.info("-channels: \(ref, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }
    #endif

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
