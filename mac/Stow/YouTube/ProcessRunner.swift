import Foundation
import os

struct ProcessOutput: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: String
}

enum ProcessRunner {
    private static let running = OSAllocatedUnfairLock<[ObjectIdentifier: RunningProcess]>(initialState: [:])

    /// Terminates every process still running, so none outlives the app (call when quitting).
    static func terminateAll() {
        running.withLock { $0.values.forEach { $0.terminate() } }
    }

    /// Runs `executable` to completion without blocking the caller, capturing stdout/stderr.
    /// Terminates the process and throws `StowError.timedOut` after `timeout`, or
    /// `CancellationError` when the calling task is cancelled.
    /// A non-zero exit code is returned, not thrown.
    static func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolLocator.childPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Built before run() so the termination handler can't be missed.
        let exitStatus = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw StowError.processFailed(tool: executable.lastPathComponent, exitCode: -1, stderr: error.localizedDescription)
        }

        let handle = RunningProcess(process)
        running.withLock { $0[ObjectIdentifier(handle)] = handle }
        defer { running.withLock { $0[ObjectIdentifier(handle)] = nil } }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            timedOut.withLock { $0 = true }
            handle.terminate()
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently so a full pipe buffer can't stall the child.
            async let stdout = readToEnd(stdoutPipe.fileHandleForReading)
            async let stderr = readToEnd(stderrPipe.fileHandleForReading)
            let (out, err) = await (stdout, stderr)
            var exitCode: Int32 = -1
            for await status in exitStatus { exitCode = status }

            if timedOut.withLock({ $0 }) { throw StowError.timedOut(tool: executable.lastPathComponent) }
            try Task.checkCancellation()
            return ProcessOutput(exitCode: exitCode, stdout: out, stderr: String(decoding: err, as: UTF8.self))
        } onCancel: {
            handle.terminate()
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }
}

/// Lets the watchdog and cancellation handler signal the process from other threads.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) { self.process = process }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
