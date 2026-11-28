import AVFoundation
import Foundation
import Observation
import os

/// What the download queue needs from the rest of the app (the Repository).
@MainActor
public protocol DownloadHost: AnyObject {
    /// The video to download, from what's loaded or from the server; nil when it's gone.
    /// Throws `.notPaired` when the Mac unpaired this phone.
    func videoToDownload(_ id: String) async throws -> Video?
    /// A temporary cookies.txt for members-only videos (the queue deletes it), or nil.
    func cookiesFile() async -> URL?
    func downloadFinished(_ video: Video)
    /// What to say instead of the tool's error (standalone's sign-in messages), or nil.
    func downloadFailure(_ video: Video, error: Error?) -> String?
}

public extension DownloadHost {
    func downloadFailure(_ video: Video, error: Error?) -> String? { nil }
}

/// Downloads one video at a time through the `YouTubeTool`, in the order they were asked for.
///
/// Like the Android app's WorkManager jobs: it waits for Wi-Fi (or any network, as set), stops a
/// download when the network no longer qualifies and resumes it later, and retries a failed one
/// three times with growing pauses (2, 4, 8 minutes) before marking it failed. The queue is kept
/// on disk, so it survives the app being closed.
@MainActor
@Observable
public final class DownloadManager {
    /// The video downloading now.
    public private(set) var activeId: String?
    /// Waiting, in order (the active one included).
    public var queuedIds: [String] { queue.map(\.id) }
    /// Whether anything is queued that could run on this network.
    public var isWaitingForNetwork: Bool {
        !queue.isEmpty && activeId == nil && !networkStatus.allowsDownloads(wifiOnly: prefs.wifiOnly)
    }

    /// The network as of its last change (observable, unlike the monitor).
    public private(set) var networkStatus: NetworkStatus
    /// Stopped by the app because iOS is about to suspend it (`suspend()`), until `resume()`.
    public private(set) var isSuspended = false

    /// Why waiting downloads aren't running, for the screen to say so.
    public enum Hold: Equatable, Sendable {
        /// Nothing holds them (they run in turn, or wait for a retry).
        case none
        case noConnection
        /// Connected, but only to a metered network and "Wi-Fi only" is on.
        case waitingForWiFi
        /// iOS stopped giving the app time in the background.
        case suspended
    }

    public var hold: Hold {
        if isSuspended { return .suspended }
        if !networkStatus.isConnected { return .noConnection }
        if !networkStatus.allowsDownloads(wifiOnly: prefs.wifiOnly) { return .waitingForWiFi }
        return .none
    }

    /// True while a download runs: the app holds a background task meanwhile, so iOS gives it
    /// time to finish after the app leaves the screen.
    @ObservationIgnored public var onBusyChange: ((Bool) -> Void)?

    struct Entry: Codable, Hashable {
        var id: String
        /// Failed tries so far.
        var attempts = 0
        var notBefore: Date?
    }

    @ObservationIgnored private var queue: [Entry] = [] {
        didSet { saveQueue() }
    }
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Canceled for good while running: what it downloaded goes once it has stopped.
    @ObservationIgnored private var discarded: Set<String> = []
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private let local: LocalStore
    @ObservationIgnored private let prefs: Prefs
    @ObservationIgnored private let network: NetworkMonitoring
    @ObservationIgnored private let tool: YouTubeTool
    @ObservationIgnored private let file: URL
    @ObservationIgnored weak var host: DownloadHost?
    @ObservationIgnored private let log = Logger(subsystem: "dev.stow.ios", category: "downloads")

    /// Retries after a failure: 3, as on Android.
    @ObservationIgnored var maxRetries = 3
    /// The pause before retry `attempt` (1, 2, 3): 2, 4, 8 minutes.
    @ObservationIgnored var retryDelay: (Int) -> TimeInterval = { attempt in 120 * pow(2, Double(attempt - 1)) }
    /// Reads a downloaded file's length in milliseconds.
    @ObservationIgnored var mediaDurationMs: @Sendable (URL) async -> Int = { url in
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return 0 }
        return Int(duration.seconds * 1000)
    }

    init(local: LocalStore, prefs: Prefs, network: NetworkMonitoring, tool: YouTubeTool, directory: URL) {
        self.local = local
        self.prefs = prefs
        self.network = network
        self.tool = tool
        file = directory.appending(path: "download-queue.json")
        networkStatus = network.status
        queue = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.stow.decode([Entry].self, from: $0) } ?? []
        network.onChange = { [weak self] status in
            self?.networkStatus = status
            self?.reevaluate()
        }
    }

    /// After launch: anything the store says is waiting or was cut off goes (back) in the queue.
    func restore() {
        for video in local.videos.values.sorted(by: { $0.updatedAt < $1.updatedAt })
        where video.state == .queued || video.state == .downloading {
            if video.state == .downloading { local.update(video.id) { $0.map { var v = $0; v.state = .queued; return v } } }
            if !queue.contains(where: { $0.id == video.id }) { queue.append(Entry(id: video.id)) }
        }
        queue.removeAll { entry in
            let state = local[entry.id]?.state
            return state != .queued && state != .downloading
        }
        pruneParts()
        pump()
    }

    /// Partial downloads of videos no longer waiting (deleted, or failed for good) only take space.
    private func pruneParts() {
        let folder = local.downloadsDirectory.appending(path: LocalStore.partsFolder, directoryHint: .isDirectory)
        let waiting = Set(queue.map(\.id))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !waiting.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// Adds a download, unless it's already waiting. `fresh` clears its failed tries (a new ask).
    public func enqueue(_ id: String, fresh: Bool = false) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            if fresh, activeId != id { queue[index] = Entry(id: id) }
        } else {
            queue.append(Entry(id: id))
        }
        pump()
    }

    /// Stops and forgets a download (deleted, or canceled by the user), and what it had downloaded.
    public func cancel(_ id: String) {
        queue.removeAll { $0.id == id }
        if activeId == id {
            discarded.insert(id)
            stopActive()
        } else {
            try? FileManager.default.removeItem(at: local.partsDirectory(for: id))
        }
    }

    /// iOS is about to suspend the app: stops the running download, keeping what's down so far,
    /// and starts none until `resume()`. A download cut off mid-write by the suspension would
    /// only fail later.
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        if activeId != nil {
            log.info("Suspending downloads")
            stopActive()
        }
    }

    /// The app is running again (on screen, or in a background task): downloads go on.
    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        pump()
    }

    /// The network or the Wi-Fi rule changed: stop what may no longer run, start what may.
    public func reevaluate() {
        if activeId != nil, !network.status.allowsDownloads(wifiOnly: prefs.wifiOnly) {
            log.info("Network no longer allows downloads; pausing")
            stopActive()
        }
        pump()
    }

    /// Waits until nothing is running (for background tasks and tests).
    public func waitUntilIdle() async {
        while let running { await running.value; if self.running == running { break } }
    }

    // Running

    private func stopActive() {
        if let activeId { tool.cancel(videoId: activeId) }
        running?.cancel()
    }

    private func pump() {
        guard running == nil, !isSuspended, network.status.allowsDownloads(wifiOnly: prefs.wifiOnly) else { return }
        let now = Date.now
        guard let entry = queue.first(where: { ($0.notBefore ?? .distantPast) <= now }) else {
            scheduleWake()
            return
        }
        wake?.cancel()
        wake = nil
        activeId = entry.id
        onBusyChange?(true)
        running = Task { [weak self] in
            await self?.run(entry)
            guard let self else { return }
            self.running = nil
            self.activeId = nil
            if self.discarded.remove(entry.id) != nil { self.local.deleteFiles(for: entry.id) }
            self.pump()
            if self.running == nil { self.onBusyChange?(false) }
        }
    }

    /// Sleeps until the earliest retry is due.
    private func scheduleWake() {
        wake?.cancel()
        guard let next = queue.compactMap(\.notBefore).min() else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0) + 0.05))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    private func run(_ entry: Entry) async {
        let id = entry.id
        let video: Video?
        do {
            video = try await host?.videoToDownload(id)
        } catch StowError.notPaired {
            finish(id)
            return
        } catch {
            // Can't reach the server to find it: try again later, without counting it as a failure.
            postpone(id, by: retryDelay(1))
            return
        }
        guard let video, !Task.isCancelled else {
            if video == nil {
                // Nothing knows what it is any more: say so rather than leave it waiting forever.
                local.update(id) { existing in
                    guard var gone = existing, gone.state == .queued || gone.state == .downloading else { return existing }
                    gone.state = .failed
                    gone.error = "This video isn't on the Mac's list any more."
                    return gone
                }
                finish(id)
            }
            return
        }
        if let existing = local[id] {
            if existing.state == .deleted || (existing.state == .downloaded && local.fileURL(for: id) != nil) {
                finish(id)
                return
            }
        }
        local.update(id) { existing in
            var record = existing ?? LocalVideo(id: id, state: .queued)
            record.state = .downloading
            record.progress = 0
            record.error = nil
            if record.video == nil { record.video = video }
            return record
        }
        // Cookies only for members-only videos: sharing the session from a second IP more than
        // needed risks YouTube rotating it on the Mac too.
        let cookies = video.isMembersOnly ? await host?.cookiesFile() : nil
        defer { if let cookies { try? FileManager.default.removeItem(at: cookies) } }
        do {
            try Task.checkCancellation()
            let folder = local.downloadsDirectory
            let downloaded = try await tool.download(video, cookies: cookies, quality: prefs.downloadQuality, to: folder) { [weak self] fraction in
                let percent = min(max(Int(fraction * 100), 0), 100)
                Task { @MainActor in self?.progress(id, percent) }
            }
            try Task.checkCancellation()
            let file = try moveIntoFolder(downloaded, id: id, folder: folder)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let duration = await mediaDurationMs(file)
            local.update(id) { existing in
                var video = existing ?? LocalVideo(id: id, state: .downloaded)
                video.state = .downloaded
                video.progress = 100
                video.error = nil
                video.fileName = file.lastPathComponent
                video.sizeBytes = size
                if duration > 0 { video.durationMs = duration }
                video.downloadedAt = .now
                return video
            }
            finish(id)
            host?.downloadFinished(video)
        } catch {
            if error is CancellationError || Task.isCancelled {
                // Stopped (deleted, network rule changed): not a failure. A deleted one stays deleted.
                local.update(id) { existing in
                    guard var video = existing, video.state == .downloading else { return existing }
                    video.state = .queued
                    video.error = nil
                    return video
                }
                return
            }
            let message = host?.downloadFailure(video, error: error) ?? Self.message(error)
            let attempts = (queue.first { $0.id == id }?.attempts ?? entry.attempts) + 1
            log.warning("Download \(id, privacy: .public) failed (attempt \(attempts)): \(message, privacy: .public)")
            if attempts <= maxRetries {
                local.update(id) { $0.map { var v = $0; v.state = .queued; v.error = message; return v } }
                if let index = queue.firstIndex(where: { $0.id == id }) {
                    queue[index].attempts = attempts
                    queue[index].notBefore = .now.addingTimeInterval(retryDelay(attempts))
                }
            } else {
                local.update(id) { $0.map { var v = $0; v.state = .failed; v.error = message; return v } }
                finish(id)
            }
        }
    }

    private func progress(_ id: String, _ percent: Int) {
        guard local[id]?.state == .downloading else { return }
        local.setProgress(id, percent)
    }

    private func finish(_ id: String) {
        queue.removeAll { $0.id == id }
    }

    private func postpone(_ id: String, by delay: TimeInterval) {
        if let index = queue.firstIndex(where: { $0.id == id }) { queue[index].notBefore = .now.addingTimeInterval(delay) }
    }

    /// The tool may have left the file elsewhere (a temporary folder): it belongs in the downloads folder.
    private func moveIntoFolder(_ file: URL, id: String, folder: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: file.path) else { throw StowError.server("The download finished but no file was found") }
        if file.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path { return file }
        let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension
        let target = folder.appending(path: "\(id).\(ext)")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    private func saveQueue() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.stow.encode(queue) { try? data.write(to: file, options: .atomic) }
    }

    static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return String(text.prefix(300))
    }
}
