#if DEBUG
import AppKit
import SwiftUI

/// `Stow --snapshot <dir>` (Debug builds only): renders the menu panel and every Settings screen
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
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let model = try makeModel()
            await model.signIn()
            NSApplication.shared.setActivationPolicy(.prohibited)

            let screens: [(String, AnyView)] = [
                ("menu", AnyView(MenuContent())),
                ("settings", AnyView(SettingsView().frame(width: 640, height: 480))),
                ("channels", AnyView(ChannelsTab().frame(width: 640, height: 440))),
                ("account", AnyView(AccountTab().frame(width: 640, height: 440))),
                ("alarm", AnyView(AlarmTab().frame(width: 640, height: 440))),
                ("log", AnyView(LogTab().frame(width: 640, height: 440))),
                ("subscriptions", AnyView(SubscriptionsPicker())),
            ]
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                for (name, view) in screens {
                    let url = output.appending(path: "\(name)-\(suffix).png")
                    try await render(view.environment(model), appearance: appearance, to: url)
                    print(url.path)
                }
            }
            return true
        } catch {
            print("Snapshot failed: \(error)")
            return false
        }
    }

    private static func makeModel() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in [AppPaths.settingsFile, AppPaths.stateFile, AppPaths.logFile]
        where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.copyItem(at: file, to: directory.appending(path: file.lastPathComponent))
        }
        let model = AppModel(youtube: YouTubeClient(), account: SnapshotAccount(),
                             store: Store(directory: directory), notifier: SilentNotifier(),
                             cookiesFile: directory.appending(path: "cookies.txt"))
        model.load()
        return model
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
