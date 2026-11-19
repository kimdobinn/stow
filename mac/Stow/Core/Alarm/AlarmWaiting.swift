import Foundation
import os

/// Waiting helpers for the alarm run, which must never hang on a slow network or a missing device.
enum AlarmWaiting {
    /// Sleeps until the wall-clock `date` (re-checked every few seconds, so time spent asleep
    /// counts). Throws `CancellationError` when the task is cancelled.
    static func sleep(until date: Date) async throws {
        while true {
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(for: .seconds(min(remaining, 5)))
        }
    }

    /// `work`'s result, or nil when it takes longer than `limit` or the calling task is
    /// cancelled. `work` is not cancelled; it keeps running.
    static func value<T: Sendable>(of work: Task<T, Never>, within limit: Duration) async -> T? {
        let once = Once<T?>()
        let timer = Task {
            try? await Task.sleep(for: limit)
            once.resume(nil)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.set(continuation)
                Task { once.resume(await work.value) }
            }
        } onCancel: {
            once.resume(nil)
        }
    }

    /// Polls `condition` every half second until it holds or `limit` passes.
    @MainActor
    static func poll(within limit: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(500))) != nil else { return false }
        }
        return true
    }
}

/// Resumes a continuation exactly once, whichever side arrives first.
private final class Once<T: Sendable>: Sendable {
    private enum State {
        case waiting(CheckedContinuation<T, Never>?)
        case resolved(T)
        case done
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .waiting(nil))

    func set(_ continuation: CheckedContinuation<T, Never>) {
        let early: T? = state.withLock { state in
            guard case .resolved(let value) = state else {
                state = .waiting(continuation)
                return nil
            }
            state = .done
            return value
        }
        if let early { continuation.resume(returning: early) }
    }

    func resume(_ value: T) {
        let continuation: CheckedContinuation<T, Never>? = state.withLock { state in
            switch state {
            case .waiting(let continuation?):
                state = .done
                return continuation
            case .waiting(nil):
                state = .resolved(value)
                return nil
            case .resolved, .done:
                return nil
            }
        }
        continuation?.resume(returning: value)
    }
}
