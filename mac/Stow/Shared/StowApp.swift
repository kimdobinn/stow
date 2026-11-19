import AppKit
import SwiftUI

enum SceneID {
    static let main = "main"
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
        #if DEBUG
        if CommandLine.arguments.contains(Snapshot.argument) {
            Task { exit(await Snapshot.run() ? 0 : 1) }
            NSApplication.shared.run()
        }
        #endif
        // Two copies (e.g. a dev build and the installed app) would double every check and alarm.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let running = others.first(where: { $0.processIdentifier != getpid() }) {
            running.activate()
            exit(0)
        }
        StowApp.main()
    }
}

struct StowApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
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
        Window("Stow", id: SceneID.main) {
            MainView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Check Now") { Task { await model.checkNow() } }
                    .keyboardShortcut("r")
                    .disabled(model.isChecking)
            }
        }
    }
}

/// Stow keeps checking (and, later, runs the alarm) with its window closed; the Dock icon brings it back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
