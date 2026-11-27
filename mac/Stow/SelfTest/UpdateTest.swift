#if DEBUG || STOW_TEST_OVERRIDES
import Foundation

/// `Stow --update-test <report file>` (Debug builds, and test builds made with STOW_TEST_OVERRIDES):
/// runs the in-app update headless. It appends "started <version> <path>" to the report, checks
/// STOW_UPDATE_FEED_URL (a local fake of GitHub's releases list) and, when that offers a newer
/// version, downloads, verifies and swaps it in exactly like "Update and Relaunch", then relaunches
/// the new copy with the same arguments, which reports its own version. Settings, state and the
/// installed app are never touched; nothing is remembered between runs.
@MainActor
enum UpdateTest {
    static let argument = "--update-test"

    static func run() async -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: argument), args.indices.contains(index + 1) else {
            print("usage: STOW_UPDATE_FEED_URL=<url> Stow --update-test <report file>")
            return false
        }
        let report = URL(filePath: args[index + 1])
        let version = DottedVersion.running?.description ?? "unknown"
        append("started \(version) \(Bundle.main.bundleURL.path) pid \(getpid())", to: report)

        let updater = AppUpdater(defaults: nil, log: { level, message in
            print("log \(level.rawValue): \(message)")
            append("log \(level.rawValue): \(message)", to: report)
        }, relaunchArguments: [argument, report.path], terminate: {
            append("relaunching", to: report)
            exit(0)
        })
        await updater.checkNow()
        switch updater.status {
        case .available(let release):
            append("found \(release.version)", to: report)
            await updater.install()
            append("install failed: \(updater.installError ?? "unknown")", to: report)
            return false
        case .upToDate:
            append("up to date at \(version)", to: report)
            return true
        default:
            append("check failed: \(updater.status)", to: report)
            return false
        }
    }

    private static func append(_ line: String, to report: URL) {
        print(line)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: report) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: report)
        }
    }
}
#endif
