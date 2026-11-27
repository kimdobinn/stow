import Foundation
import Observation

/// Keeps Stow's own yt-dlp (the official standalone yt-dlp_macos) current, so a YouTube change is
/// fixed as soon as yt-dlp ships the fix. It lives in Application Support/Stow/bin/yt-dlp, which
/// `ToolLocator` prefers over Homebrew's; without it (or when it doesn't run) Homebrew's is used.
/// Checked at launch and then at most once a day; never while the alarm runs or is near.
@MainActor
@Observable
final class YtDlpUpdater {
    /// The version of Stow's copy; nil when there is none (Homebrew's is used).
    private(set) var installedVersion: DottedVersion?
    private(set) var isUpdating = false
    private(set) var lastChecked: Date?
    /// Why the last check or update failed; nil once one succeeds.
    private(set) var lastError: String?

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let latestURL: URL
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let blocker: @MainActor () -> UpdateGate.Block?
    @ObservationIgnored private let log: @MainActor (LogLevel, String) -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?

    private static let lastCheckedKey = "ytdlp.lastChecked"
    nonisolated static let binaryName = "yt-dlp"

    var binary: URL { directory.appending(path: Self.binaryName) }

    init(directory: URL = AppPaths.binDirectory, latestURL: URL = UpdateEndpoints.ytDlpLatest,
         defaults: UserDefaults? = .standard, blocker: @escaping @MainActor () -> UpdateGate.Block? = { nil },
         log: @escaping @MainActor (LogLevel, String) -> Void = { _, _ in }) {
        self.directory = directory
        self.latestURL = latestURL
        self.defaults = defaults
        self.blocker = blocker
        self.log = log
        lastChecked = defaults?.object(forKey: Self.lastCheckedKey) as? Date
    }

    /// Checks that Stow's copy still runs (removing it if not), then updates it when a day has
    /// passed since the last check, and looks again every hour.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.validateInstalled()
            while !Task.isCancelled {
                guard let self else { return }
                if DailyCheck.isDue(lastChecked: self.lastChecked) { await self.update() }
                try? await Task.sleep(for: DailyCheck.tick)
            }
        }
    }

    /// Runs Stow's copy with --version; one that doesn't run is deleted, so Homebrew's is used.
    func validateInstalled() async {
        guard FileManager.default.fileExists(atPath: binary.path) else {
            installedVersion = nil
            return
        }
        do {
            installedVersion = try await Self.version(of: binary)
        } catch {
            try? FileManager.default.removeItem(at: binary)
            installedVersion = nil
            lastError = "Stow's yt-dlp didn't run, so Homebrew's is used: \((error as? UpdateError)?.errorDescription ?? error.logDescription)"
            log(.warning, lastError ?? "")
        }
    }

    /// Updates to yt-dlp's latest release if it's newer than Stow's copy (or there is none).
    /// Returns without doing anything while the alarm runs or is near (it's tried again later).
    func update() async {
        guard !isUpdating else { return }
        if let block = blocker() {
            lastError = block.ytDlpMessage
            return
        }
        isUpdating = true
        defer { isUpdating = false }
        do {
            let release = try await Self.latestRelease(from: latestURL)
            lastChecked = .now
            defaults?.set(lastChecked, forKey: Self.lastCheckedKey)
            if let installedVersion, installedVersion >= release.version {
                lastError = nil
                return
            }
            let staged = try await Self.prepare(release, in: directory)
            if let block = blocker() {
                try? FileManager.default.removeItem(at: staged.file)
                lastError = block.ytDlpMessage
                return
            }
            try Self.commit(staged.file, to: binary)
            let previous = installedVersion
            installedVersion = staged.version
            lastError = nil
            log(.info, previous == nil ? "Installed yt-dlp \(staged.version) for Stow." : "Updated yt-dlp from \(previous!) to \(staged.version).")
        } catch {
            lastError = "Couldn't update yt-dlp: \((error as? UpdateError)?.errorDescription ?? error.logDescription)"
            log(.warning, lastError ?? "")
        }
    }

    // MARK: Steps (static, so tests can run them against a temporary folder)

    nonisolated static func latestRelease(from url: URL) async throws -> YtDlpRelease {
        let release = try GitHubRelease.decodeOne(try await UpdateEndpoints.fetch(url))
        guard let parsed = YtDlpRelease(release: release) else {
            throw UpdateError.bundle("yt-dlp's latest release (\(release.tagName)) has no \(YtDlpRelease.binaryName).")
        }
        return parsed
    }

    /// Downloads the release's yt-dlp_macos next to where it goes, checks it against the release's
    /// SHA2-256SUMS, makes it executable and runs it. Returns the staged file and its version.
    nonisolated static func prepare(_ release: YtDlpRelease, in directory: URL) async throws -> (file: URL, version: DottedVersion) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sums = SHA256Sums.parse(String(decoding: try await UpdateEndpoints.fetch(release.checksumsURL), as: UTF8.self))
        guard let expected = sums[YtDlpRelease.binaryName] else {
            throw UpdateError.checksum("\(YtDlpRelease.checksumsName) has no line for \(YtDlpRelease.binaryName).")
        }
        let staged = directory.appending(path: "\(binaryName).download")
        do {
            try await FileDownload.download(release.binaryURL, to: staged)
            guard try SHA256Sums.digest(of: staged) == expected else {
                throw UpdateError.checksum("The yt-dlp download doesn't match \(YtDlpRelease.checksumsName).")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            try BundleInstaller.removeQuarantine(in: staged)
            let version = try await version(of: staged)
            return (staged, version)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Moves the staged binary into place in one rename (a running yt-dlp keeps the old file).
    nonisolated static func commit(_ staged: URL, to binary: URL) throws {
        guard rename(staged.path, binary.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError.install("Couldn't put yt-dlp in place: \(message)")
        }
    }

    /// `yt-dlp --version`. The standalone build unpacks itself on each run, so the first run can be slow.
    nonisolated static func version(of binary: URL) async throws -> DottedVersion {
        let result = try await UpdateProcess.run(binary, ["--ignore-config", "--version"], timeout: .seconds(90))
        guard result.exitCode == 0 else {
            throw UpdateError.tool("yt-dlp --version failed (exit \(result.exitCode)): \(result.stderr.suffix(300))")
        }
        guard let line = result.stdout.split(whereSeparator: \.isNewline).last, let version = DottedVersion(String(line)) else {
            throw UpdateError.tool("yt-dlp printed no version: \(result.stdout.prefix(200))")
        }
        return version
    }
}

#if DEBUG
extension YtDlpUpdater {
    /// For previews and snapshots.
    static func preview(version: DottedVersion?) -> YtDlpUpdater {
        let updater = YtDlpUpdater(directory: FileManager.default.temporaryDirectory.appending(path: "stow-preview-bin"), defaults: nil)
        updater.installedVersion = version
        updater.lastChecked = .now.addingTimeInterval(-2 * 3600)
        return updater
    }
}
#endif
