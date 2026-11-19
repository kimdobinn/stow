import Foundation
import os

/// An mpv core running inside Stow (libmpv) plus the files that must disappear with it (the IPC
/// socket's folder, the cookies copy). mpv is driven over its JSON IPC socket like a separate
/// player would be; the core only adds loading files and drawing video into Stow's window.
/// Every live core is registered so `terminateAll()` can shut them down when the app quits.
final class MPVCore: @unchecked Sendable {
    private static let running = OSAllocatedUnfairLock<[ObjectIdentifier: MPVCore]>(initialState: [:])

    let api: LibMPV
    let handle: LibMPV.Handle
    private let leftovers: [URL]

    private struct State {
        var isShutDown = false
        var isFinished = false
        var releaseVideo: (@MainActor () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Signaled by `finish()` once the video output is gone; the core may be destroyed then.
    private let videoReleased = DispatchSemaphore(value: 0)
    private let destroyed = DispatchSemaphore(value: 0)

    /// Creates and starts the core with `options` (name, value). On failure removes `leftovers`
    /// and throws `.player`.
    init(options: [(String, String)], leftovers: [URL]) throws {
        self.leftovers = leftovers
        do {
            api = try LibMPV.load()
        } catch {
            Self.remove(leftovers)
            throw error
        }
        guard let handle = api.create() else {
            Self.remove(leftovers)
            throw StowError.player("Couldn't create an mpv player.")
        }
        self.handle = handle
        for (name, value) in options {
            let status = api.setOptionString(handle, name, value)
            if status < 0 {
                api.terminateDestroy(handle)
                Self.remove(leftovers)
                throw StowError.player("mpv rejected \(name)=\(value): \(api.describe(status)).")
            }
        }
        let status = api.initialize(handle)
        if status < 0 {
            api.terminateDestroy(handle)
            Self.remove(leftovers)
            throw StowError.player("Couldn't start mpv: \(api.describe(status)).")
        }
        let thread = Thread { [self] in eventLoop() }
        thread.name = "mpv events"
        thread.start()
        Self.running.withLock { $0[ObjectIdentifier(self)] = self }
    }

    /// False once mpv has shut down (playlist done, quit, or a fatal error).
    var isRunning: Bool { !state.withLock(\.isShutDown) }

    /// An in-process core has no exit code.
    var exitCode: Int32 { 0 }

    /// `release` frees the video output (render context); it runs on the main thread before the
    /// core is destroyed.
    func setVideoRelease(_ release: @escaping @MainActor () -> Void) {
        state.withLock { $0.releaseVideo = release }
    }

    /// Appends `urls` to the playlist; playback starts with the first. False if mpv refused one.
    func load(_ urls: [URL]) -> Bool {
        urls.allSatisfy { api.run(handle, ["loadfile", $0.absoluteString, "append-play"]) >= 0 }
    }

    /// Asks mpv to quit (it then shuts down).
    func terminate() {
        if isRunning { api.run(handle, ["quit"]) }
    }

    /// In process there's nothing harder than quitting; `finish()` destroys the core.
    func kill() {
        terminate()
    }

    /// Returns whether mpv shut down within `timeout`.
    func waitForExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isRunning
    }

    /// Frees the video output, shuts mpv down and destroys it, deletes its files and unregisters
    /// it. Idempotent; blocks for at most a few seconds.
    func finish() {
        let release: (@MainActor () -> Void)?? = state.withLock { state in
            guard !state.isFinished else { return .none }
            state.isFinished = true
            defer { state.releaseVideo = nil }
            return .some(state.releaseVideo)
        }
        guard case .some(let releaseVideo) = release else { return }
        if let releaseVideo {
            if Thread.isMainThread {
                MainActor.assumeIsolated { releaseVideo() }
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated { releaseVideo() } }
            }
        }
        terminate()
        videoReleased.signal()
        _ = destroyed.wait(timeout: .now() + 5)
        Self.remove(leftovers)
        Self.running.withLock { $0[ObjectIdentifier(self)] = nil }
    }

    static func terminateAll() {
        running.withLock { Array($0.values) }.forEach { $0.finish() }
    }

    /// Drains mpv's events (the IPC socket carries the ones Stow uses) until shutdown, then
    /// destroys the core once the video output has been freed.
    private func eventLoop() {
        while true {
            guard let event = api.waitEvent(handle, -1) else { continue }
            if event.pointee.event_id == MPV_EVENT_SHUTDOWN { break }
        }
        state.withLock { $0.isShutDown = true }
        videoReleased.wait()
        api.terminateDestroy(handle)
        destroyed.signal()
    }

    private static func remove(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
