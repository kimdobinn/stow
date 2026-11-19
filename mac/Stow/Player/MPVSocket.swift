import Foundation
import os

/// A connected UNIX socket to mpv's `--input-ipc-server`. Writes are serialized; reading happens
/// on a dedicated thread and is delivered as lines.
final class MPVSocket: Sendable {
    private let descriptor: Int32
    /// False once the reader thread has closed the descriptor; guards every use of it.
    private let isOpen = OSAllocatedUnfairLock(initialState: true)

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Connects to `path`, retrying until mpv has created it. Gives up after `timeout` or as soon as
    /// `isAlive` returns false (mpv exited).
    static func connect(path: String, timeout: Duration, isAlive: @Sendable () -> Bool) async throws -> MPVSocket {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let socket = try attempt(path: path) { return socket }
            guard isAlive(), ContinuousClock.now < deadline else {
                throw StowError.player("Couldn't connect to mpv's control socket.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// nil when mpv hasn't created the socket yet.
    private static func attempt(path: String) throws -> MPVSocket? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw StowError.player("Socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StowError.player("socket() failed: \(errno)") }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return MPVSocket(descriptor: descriptor)
    }

    /// Writes `data` completely. Throws when mpv has gone away.
    func send(_ data: Data) throws {
        try isOpen.withLock { open in
            guard open else { throw StowError.player("mpv's control socket closed.") }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw StowError.player("mpv's control socket closed.")
                    }
                    offset += written
                }
            }
        }
    }

    /// Lines from mpv until it closes the socket or `shutdown()` is called; closes the
    /// descriptor afterwards. Call once.
    func lines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let descriptor = descriptor
            let isOpen = isOpen
            let thread = Thread {
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = read(descriptor, &chunk, chunk.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    buffer.append(contentsOf: chunk[0..<count])
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        continuation.yield(Data(buffer[buffer.startIndex..<newline]))
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                }
                isOpen.withLock { open in
                    open = false
                    close(descriptor)
                }
                continuation.finish()
            }
            thread.name = "Stow mpv IPC"
            thread.start()
        }
    }

    /// Ends `lines()` (and so closes the socket).
    func shutdown() {
        isOpen.withLock { open in
            if open { Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }
}
