import AppKit
import SwiftUI

enum SceneID {
    static let settings = "settings"
}

/// Entry point: `Stow --selftest` runs the headless self-test instead of the app.
@main
@MainActor
enum StowMain {
    static func main() {
        if CommandLine.arguments.contains(SelfTest.argument) {
            Task { exit(await SelfTest.run() ? 0 : 1) }
            dispatchMain()
        }
        // Two copies (e.g. a dev build and the installed app) would double every check and alarm.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           others.contains(where: { $0.processIdentifier != getpid() }) {
            exit(0)
        }
        StowApp.main()
    }
}

struct StowApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel(youtube: YouTubeClient(), account: AccountManager())
        // Unit tests are hosted by the app; don't touch the network or real files then.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Self.cleanUpCookieCopies()
            model.start()
        }
        _model = State(initialValue: model)
    }

    /// yt-dlp's cookie copies must not outlive a run: remove any left by a previous quit, and on
    /// quit stop yt-dlp first so it can't write its copy back afterwards.
    private static func cleanUpCookieCopies() {
        MembersFetcher.removeCopies(for: AppPaths.cookiesFile)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ProcessRunner.terminateAll()
            MembersFetcher.removeCopies(for: AppPaths.cookiesFile)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Stow Settings", id: SceneID.settings) {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
