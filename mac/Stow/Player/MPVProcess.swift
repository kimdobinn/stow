import Foundation
import os

/// A running mpv child process plus the files that must disappear with it (the IPC socket's
/// folder, the cookies copy). Every live instance is registered so `terminateAll()` can kill
/// them synchronously when the app quits.
final class MPVProcess: @unchecked Sendable {
    private static let running = OSAllocatedUnfairLock<[ObjectIdentifier: MPVProcess]>(initialState: [:])

    private let process: Process
    private let leftovers: [URL]

    /// Starts `executable`; on failure removes `leftovers` and throws `.player`.
    init(executable: URL, arguments: [String], leftovers: [URL]) throws {
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolLocator.childPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.leftovers = leftovers
        do {
            try process.run()
        } catch {
            removeLeftovers()
            throw StowError.player("Couldn't start mpv: \(error.localizedDescription)")
        }
        Self.running.withLock { $0[ObjectIdentifier(self)] = self }
    }

    var isRunning: Bool { process.isRunning }

    /// Valid once `isRunning` is false.
    var exitCode: Int32 { process.terminationStatus }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    /// Returns whether the process exited within `timeout`.
    func waitForExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    /// Kills the process if needed, deletes its files and unregisters it. Idempotent.
    func finish() {
        if process.isRunning {
            terminate()
            let deadline = Date.now.addingTimeInterval(1)
            while process.isRunning, Date.now < deadline { usleep(20_000) }
            kill()
        }
        removeLeftovers()
        Self.running.withLock { $0[ObjectIdentifier(self)] = nil }
    }

    static func terminateAll() {
        running.withLock { Array($0.values) }.forEach { $0.finish() }
    }

    private func removeLeftovers() {
        for url in leftovers { try? FileManager.default.removeItem(at: url) }
    }
}
