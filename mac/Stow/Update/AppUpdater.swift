import AppKit
import Foundation
import Observation

/// Keeps Stow for Mac up to date from the GitHub pre-releases tagged mac-v<version>: checks at
/// most once a day (and on demand), and on request downloads, verifies and swaps in the new app,
/// then relaunches it.
@MainActor
@Observable
final class AppUpdater {
    enum Status: Equatable {
        case notChecked
        case checking
        case upToDate
        case available(MacRelease)
        case failed(String)
    }

    enum InstallPhase: Equatable {
        /// 0…1, nil while the size is unknown.
        case downloading(Double?)
        case verifying
        case installing
    }

    let currentVersion: DottedVersion?
    private(set) var status: Status = .notChecked
    private(set) var lastChecked: Date?
    private(set) var installPhase: InstallPhase?
    /// Why the last update attempt didn't happen.
    private(set) var installError: String?

    var availableRelease: MacRelease? {
        if case .available(let release) = status { return release }
        return nil
    }

    @ObservationIgnored private let feedURL: URL
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let blocker: @MainActor () -> UpdateGate.Block?
    @ObservationIgnored private let log: @MainActor (LogLevel, String) -> Void
    @ObservationIgnored private let relaunchArguments: [String]
    @ObservationIgnored private let terminate: @MainActor () -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?

    private static let lastCheckedKey = "updates.lastChecked"
    private static let latestKey = "updates.latestRelease"

    /// `defaults` nil keeps nothing between launches. `blocker` says when an update must wait
    /// (the alarm). `relaunchArguments` are passed to the new copy; `terminate` quits this one.
    init(feedURL: URL = UpdateEndpoints.macReleasesFeed, bundleURL: URL = Bundle.main.bundleURL,
         currentVersion: DottedVersion? = .running, defaults: UserDefaults? = .standard,
         blocker: @escaping @MainActor () -> UpdateGate.Block? = { nil },
         log: @escaping @MainActor (LogLevel, String) -> Void = { _, _ in },
         relaunchArguments: [String] = [], terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.feedURL = feedURL
        self.bundleURL = bundleURL
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.blocker = blocker
        self.log = log
        self.relaunchArguments = relaunchArguments
        self.terminate = terminate
        lastChecked = defaults?.object(forKey: Self.lastCheckedKey) as? Date
        // What the last check found, until the next one.
        if let data = defaults?.data(forKey: Self.latestKey),
           let release = try? JSONDecoder().decode(MacRelease.self, from: data) {
            status = Self.status(for: release, current: currentVersion)
        } else if lastChecked != nil {
            status = .upToDate
        }
    }

    /// Checks now if a day has passed since the last check, then hourly looks again.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self else { return }
                if DailyCheck.isDue(lastChecked: self.lastChecked) { await self.checkNow() }
                try? await Task.sleep(for: DailyCheck.tick)
            }
        }
    }

    func checkNow() async {
        guard status != .checking, installPhase == nil else { return }
        let previous = status
        status = .checking
        do {
            let data = try await UpdateEndpoints.fetch(feedURL)
            let newest = MacRelease.newest(in: try GitHubRelease.decodeList(data))
            lastChecked = .now
            defaults?.set(lastChecked, forKey: Self.lastCheckedKey)
            if let newest, let encoded = try? JSONEncoder().encode(newest) {
                defaults?.set(encoded, forKey: Self.latestKey)
            } else {
                defaults?.removeObject(forKey: Self.latestKey)
            }
            status = newest.map { Self.status(for: $0, current: currentVersion) } ?? .upToDate
            if case .available(let release) = status, previous != status {
                log(.info, "Stow \(release.version) is available (this is \(currentVersion?.description ?? "an unknown version")).")
            }
        } catch {
            status = .failed("Couldn't check for updates: \(error.logDescription)")
        }
    }

    private static func status(for release: MacRelease, current: DottedVersion?) -> Status {
        guard let current else { return .available(release) }
        return release.version > current ? .available(release) : .upToDate
    }

    /// Downloads, verifies and installs the available release, then relaunches. Returns only when
    /// it didn't happen (`installError` says why); the app is left as it was.
    @discardableResult
    func install() async -> Bool {
        guard installPhase == nil, let release = availableRelease else { return false }
        installError = nil
        if let block = blocker() {
            installError = block.appMessage
            return false
        }
        installPhase = .downloading(nil)
        var staging: URL?
        do {
            staging = try BundleInstaller.stagingDirectory(for: bundleURL)
            try await install(release, staging: staging!)
            return true
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            installPhase = nil
            installError = (error as? UpdateError)?.errorDescription ?? error.logDescription
            log(.warning, "Couldn't update Stow to \(release.version): \(installError ?? "")")
            return false
        }
    }

    private func install(_ release: MacRelease, staging: URL) async throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { throw UpdateError.bundle("This copy of Stow has no bundle id.") }
        guard let teamID = try CodeSignature.running().teamID else {
            throw UpdateError.signature("This copy of Stow isn't signed by a team, so it can't check the update's signature.")
        }
        guard BundleInstaller.canReplace(bundleURL) else {
            throw UpdateError.install("Stow can't replace itself at \(bundleURL.path) (no write access).")
        }

        let zip = staging.appending(path: release.zipURL.lastPathComponent)
        try await FileDownload.download(release.zipURL, to: zip) { fraction in
            Task { @MainActor [weak self] in
                if case .downloading = self?.installPhase { self?.installPhase = .downloading(fraction) }
            }
        }
        installPhase = .verifying
        if let expected = try await expectedChecksum(of: release) {
            let actual = try SHA256Sums.digest(of: zip)
            guard actual == expected else { throw UpdateError.checksum("The download doesn't match its published checksum.") }
        }
        let app = try await BundleInstaller.unzip(zip, into: staging.appending(path: "unzipped"))
        try BundleInstaller.removeQuarantine(in: app)
        guard !BundleInstaller.hasQuarantine(in: app) else { throw UpdateError.install("Couldn't clear the quarantine flag.") }
        try await BundleInstaller.check(app: app, bundleIdentifier: bundleIdentifier, version: release.version, teamID: teamID)

        // The download took a while: the alarm may be close now.
        if let block = blocker() { throw UpdateError.blocked(block.appMessage) }
        installPhase = .installing
        try BundleInstaller.swap(installed: bundleURL, with: app)
        do {
            // `app` now holds the old copy; the helper deletes it after the relaunch.
            try BundleInstaller.spawnRelauncher(pid: getpid(), app: bundleURL, cleanup: staging, arguments: relaunchArguments)
        } catch {
            try? BundleInstaller.swap(installed: bundleURL, with: app)
            throw error
        }
        log(.info, "Updated Stow to \(release.version). Relaunching.")
        terminate()
    }

    private func expectedChecksum(of release: MacRelease) async throws -> String? {
        if let sha256 = release.sha256 { return sha256 }
        guard let url = release.sha256URL else { return nil }
        let text = String(decoding: try await UpdateEndpoints.fetch(url), as: UTF8.self)
        let first = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard SHA256Sums.isDigest(first) else { throw UpdateError.checksum("The published checksum can't be read.") }
        return first.lowercased()
    }
}

#if DEBUG
extension AppUpdater {
    /// For previews and snapshots.
    static func preview(status: Status, installPhase: InstallPhase? = nil) -> AppUpdater {
        let updater = AppUpdater(currentVersion: .running, defaults: nil)
        updater.status = status
        updater.lastChecked = .now.addingTimeInterval(-3 * 3600)
        updater.installPhase = installPhase
        return updater
    }

    static var sampleRelease: MacRelease {
        let next = DottedVersion.running.map { "\($0.parts[0]).\(($0.parts.count > 1 ? $0.parts[1] : 0) + 1).0" } ?? "0.2.0"
        let release = GitHubRelease(
            tagName: "mac-v\(next)", name: "Stow for Mac \(next)",
            body: "- Updates itself from GitHub\n- Keeps its own yt-dlp current\n\nSHA-256: \(String(repeating: "a", count: 64))",
            draft: false, prerelease: true, publishedAt: .now,
            assets: [.init(name: "Stow-Mac-\(next).zip", browserDownloadURL: URL(string: "https://example.com/Stow-Mac-\(next).zip")!, size: 9_000_000)])
        return MacRelease(release: release)!
    }
}
#endif
