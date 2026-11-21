import AppKit
import SwiftUI

enum SceneID {
    static let main = "main"
}

/// Entry point: `Stow --selftest` and `Stow --alarm-dryrun` run headless checks instead of the app.
@main
@MainActor
enum StowMain {
    static func main() {
        if CommandLine.arguments.contains(SelfTest.argument) {
            Task { exit(await SelfTest.run() ? 0 : 1) }
            dispatchMain()
        }
        if CommandLine.arguments.contains(AlarmDryRun.argument) {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { exit(await AlarmDryRun.run() ? 0 : 1) }
            dispatchMain()
        }
        #if DEBUG
        if CommandLine.arguments.contains(Snapshot.argument) {
            Task { exit(await Snapshot.run() ? 0 : 1) }
            NSApplication.shared.run()
        }
        if CommandLine.arguments.contains(PhoneRestore.argument) {
            Task { exit(await PhoneRestore.run() ? 0 : 1) }
            dispatchMain()
        }
        if CommandLine.arguments.contains(DeployRules.argument) {
            Task { exit(await DeployRules.run() ? 0 : 1) }
            dispatchMain()
        }
        if CommandLine.arguments.contains(PhonePush.argument) {
            Task { exit(await PhonePush.run() ? 0 : 1) }
            dispatchMain()
        }
        if CommandLine.arguments.contains(PhoneHost.argument) {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { exit(await PhoneHost.run() ? 0 : 1) }
            dispatchMain()
        }
        if CommandLine.arguments.contains(PhoneCheck.argument) {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { exit(await PhoneCheck.run() ? 0 : 1) }
            dispatchMain()
        }
        if CommandLine.arguments.contains(RemoteDemo.argument) {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { exit(await RemoteDemo.run() ? 0 : 1) }
            dispatchMain()
        }
        if CommandLine.arguments.contains(PlaybackDemo.argument) {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { exit(await PlaybackDemo.run() ? 0 : 1) }
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
        // Unit tests are hosted by the app; don't touch the network, real files or audio devices then.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            _model = State(initialValue: AppModel(youtube: YouTubeClient(), account: AccountManager(), alarmServices: .inert))
            return
        }
        let remote = AlarmRemote(pairingKeyFile: AppPaths.pairingKeyFile)
        remote.askForLocalNetworkAccess()
        let alarmServices = AlarmServices(
            player: MPVPlayer(showsControls: true), sound: AlarmSound(), outputs: CoreAudioOutputs(), speaker: BluetoothSpeaker(),
            keepAlive: KeepAlive(), power: PowerAssertions(), videoDetails: YTDLPVideoDetails(), remote: remote)
        let model = AppModel(youtube: YouTubeClient(), account: AccountManager(), alarmServices: alarmServices)
        Self.cleanUpChildProcesses()
        model.start()
        MiddleDragScroller.shared.install()
        _model = State(initialValue: model)
    }

    /// Cookie copies must not outlive a run: remove any left by a previous quit, and on quit stop
    /// yt-dlp and mpv first so they can't write their copies back afterwards.
    private static func cleanUpChildProcesses() {
        CookieCopy.removeAll(for: AppPaths.cookiesFile)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ProcessRunner.terminateAll()
            MPVPlayer.terminateAll()
            CookieCopy.removeAll(for: AppPaths.cookiesFile)
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
                Button("Stop Alarm") { model.stopAlarm() }
                    .keyboardShortcut(".")
                    .disabled(!model.isAlarmRunning)
            }
        }
    }
}

/// Stow keeps checking and runs the alarm with its window closed; the Dock icon brings it back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
