import Foundation
import JavaScriptCore
import os

/// The embedded CPython with yt-dlp (StowPython.c, Python/stow_ytdlp.py).
///
/// The interpreter starts once, on a dedicated thread that also hands every request to Python.
/// Python runs each request on a thread of its own: the GIL is released while yt-dlp waits on the
/// network, so a long download doesn't hold up a search. Each call has an id; cancelling the Swift
/// task sets a flag that Python checks before each HTTP request and on each progress update.
nonisolated final class PythonRuntime: @unchecked Sendable {
    static let shared = PythonRuntime()

    /// How long starting the interpreter took (until stow_ytdlp was imported), once it has started.
    var startupDuration: Duration? { state.withLock { $0.startupDuration } }

    private struct Call {
        var continuation: CheckedContinuation<Data, any Error>
        var onProgress: (@Sendable (Data) -> Void)?
    }

    private struct State {
        var started = false
        var startError: String?
        var startupDuration: Duration?
        var nextID: Int64 = 1
        var calls: [Int64: Call] = [:]
        var cancelled: Set<Int64> = []
        var pending: [@Sendable () -> Void] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let wake = NSCondition()
    private var thread: Thread?
    private let log = Logger(subsystem: "dev.stow.ios", category: "python")

    private init() {}

    /// Starts the interpreter if it isn't running yet and waits until it is.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            enqueue {
                if let error = self.state.withLock({ $0.startError }) {
                    continuation.resume(throwing: YtDlpError.unavailable(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Runs one request (a JSON object with "op") and returns Python's JSON answer.
    func call(_ request: [String: Any], onProgress: (@Sendable (Data) -> Void)? = nil) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: body, encoding: .utf8) else { throw YtDlpError.failed("bad request") }
        let id = state.withLock { state -> Int64 in
            defer { state.nextID += 1 }
            return state.nextID
        }
        defer { state.withLock { _ = $0.cancelled.remove(id) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                let alreadyCancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { state.cancelled.insert(id) }
                    state.calls[id] = Call(continuation: continuation, onProgress: onProgress)
                    return state.cancelled.contains(id)
                }
                if alreadyCancelled {
                    finish(id, with: .failure(CancellationError()))
                    return
                }
                enqueue {
                    if let error = self.state.withLock({ $0.startError }) {
                        self.finish(id, with: .failure(YtDlpError.unavailable(error)))
                        return
                    }
                    if let message = stow_py_submit(id, json) {
                        let text = String(cString: message)
                        stow_py_free(message)
                        self.finish(id, with: .failure(YtDlpError.failed(text)))
                    }
                }
            }
        } onCancel: {
            state.withLock { _ = $0.cancelled.insert(id) }
        }
    }

    // MARK: - The Python thread

    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        let startThread = state.withLock { state -> Bool in
            state.pending.append(work)
            if state.started { return false }
            state.started = true
            return true
        }
        if startThread {
            let thread = Thread { [unowned self] in self.runLoop() }
            thread.name = "dev.stow.python"
            thread.qualityOfService = .userInitiated
            // yt-dlp's regular expressions and the JSON encoder recurse deeply.
            thread.stackSize = 16 << 20
            self.thread = thread
            thread.start()
        }
        wake.lock()
        wake.signal()
        wake.unlock()
    }

    private func runLoop() {
        startInterpreter()
        while true {
            wake.lock()
            var work: [@Sendable () -> Void] = []
            while true {
                work = state.withLock { state in
                    defer { state.pending.removeAll() }
                    return state.pending
                }
                if !work.isEmpty { break }
                wake.wait()
            }
            wake.unlock()
            for item in work { item() }
        }
    }

    private func startInterpreter() {
        let clock = ContinuousClock()
        let began = clock.now
        let error = Self.withConfig { config in stow_py_start(&config) }
        let elapsed = clock.now - began
        state.withLock {
            $0.startError = error
            $0.startupDuration = elapsed
        }
        if let error {
            log.error("Python didn't start: \(error, privacy: .public)")
        } else {
            log.info("Python started in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        }
    }

    private static func withConfig(_ body: (inout StowPyConfig) -> UnsafeMutablePointer<CChar>?) -> String? {
        guard let resources = Bundle.main.resourceURL else { return "no app bundle" }
        let python = resources.appending(path: "python")
        let caches = URL.cachesDirectory
        let bytecode = bytecodeDirectory(in: caches.appending(path: "python-bytecode"))
        let cache = caches.appending(path: "yt-dlp")
        guard FileManager.default.fileExists(atPath: python.appending(path: "lib").path) else {
            return "the app was built without Python (run ios/scripts/fetch-python.sh)"
        }
        try? FileManager.default.createDirectory(at: bytecode, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return python.path.withCString { home in
            python.appending(path: "site-packages").path.withCString { sitePackages in
                python.appending(path: "app").path.withCString { app in
                    bytecode.path.withCString { pycache in
                        cache.path.withCString { cacheDir in
                            var config = StowPyConfig(
                                home: home, sitePackages: sitePackages, appPath: app, pycachePrefix: pycache,
                                cacheDir: cacheDir, onEvent: pythonEvent, isCancelled: pythonIsCancelled,
                                evaluateJS: evaluateJavaScript)
                            guard let message = body(&config) else { return nil }
                            defer { stow_py_free(message) }
                            return String(cString: message)
                        }
                    }
                }
            }
        }
    }

    /// Python keys its bytecode cache by the source's full path, and the app's path changes with
    /// every install or re-sign: one folder per install, and the others removed.
    private static func bytecodeDirectory(in root: URL) -> URL {
        let install = Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent
        let current = root.appending(path: install.isEmpty ? "app" : install, directoryHint: .isDirectory)
        let others = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in others where folder.lastPathComponent != current.lastPathComponent {
            try? FileManager.default.removeItem(at: folder)
        }
        return current
    }

    // MARK: - Events from Python

    fileprivate func event(_ id: Int64, kind: String, payload: Data) {
        switch kind {
        case "progress":
            let handler = state.withLock { $0.calls[id]?.onProgress }
            handler?(payload)
        case "result":
            finish(id, with: .success(payload))
        case "cancelled":
            finish(id, with: .failure(CancellationError()))
        default:
            let message = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["message"] as? String
            finish(id, with: .failure(YtDlpError.failed(message ?? "yt-dlp failed")))
        }
    }

    fileprivate func isCancelled(_ id: Int64) -> Bool {
        state.withLock { $0.cancelled.contains(id) }
    }

    private func finish(_ id: Int64, with result: Result<Data, any Error>) {
        let call = state.withLock { $0.calls.removeValue(forKey: id) }
        call?.continuation.resume(with: result)
    }
}

// C callbacks: plain functions, as C function pointers can't capture context.

nonisolated private func pythonEvent(_ id: Int64, _ kind: UnsafePointer<CChar>, _ payload: UnsafePointer<CChar>, _ length: Int64) {
    let data = Data(bytes: payload, count: Int(length))
    PythonRuntime.shared.event(id, kind: String(cString: kind), payload: data)
}

nonisolated private func pythonIsCancelled(_ id: Int64) -> Bool {
    PythonRuntime.shared.isCancelled(id)
}

/// yt-dlp's challenge solver: a script that prints its answer with console.log.
nonisolated private func evaluateJavaScript(_ script: UnsafePointer<CChar>, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<CChar>? {
    let source = String(cString: script)
    let result = JavaScriptRunner.run(source)
    switch result {
    case .success(let output):
        return strdup(output)
    case .failure(let failure):
        error.pointee = strdup(failure.message)
        return nil
    }
}

nonisolated enum JavaScriptRunner {
    struct Failure: Error { var message: String }

    /// How many scripts ran and how long they took in all (for the self-test).
    static var statistics: (runs: Int, seconds: Double) { totals.withLock { ($0.runs, $0.seconds) } }
    private static let totals = OSAllocatedUnfairLock(initialState: (runs: 0, seconds: 0.0))

    /// Runs `source` in a fresh JavaScriptCore context and returns its console.log output.
    static func run(_ source: String) -> Result<String, Failure> {
        let began = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - began
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            totals.withLock { $0.runs += 1; $0.seconds += seconds }
        }
        guard let context = JSContext() else { return .failure(Failure(message: "JavaScriptCore is unavailable")) }
        let output = OutputBuffer()
        let log: @convention(block) () -> Void = {
            let line = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }.joined(separator: " ")
            output.append(line)
        }
        // Only console.log is the answer (yt-dlp reads it as the solver's stdout).
        let ignore: @convention(block) () -> Void = {}
        let console = JSValue(newObjectIn: context)
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        console?.setObject(ignore, forKeyedSubscript: "error" as NSString)
        console?.setObject(ignore, forKeyedSubscript: "warn" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() ?? "JavaScript error" }
        context.evaluateScript(source)
        if let exception { return .failure(Failure(message: exception)) }
        return .success(output.text)
    }

    private final class OutputBuffer: @unchecked Sendable {
        private var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
        var text: String { lines.joined(separator: "\n") }
    }
}
