import CryptoKit
import Foundation

/// The "SHA2-256SUMS" format (`sha256sum` output): "<64 hex>  <name>" per line, "*" before the
/// name in binary mode.
enum SHA256Sums {
    /// File name → lowercase hex digest. Lines that don't fit the format are skipped.
    static func parse(_ text: String) -> [String: String] {
        var sums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            let digest = String(trimmed[..<space])
            var name = trimmed[space...].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard isDigest(digest), !name.isEmpty else { continue }
            sums[name] = digest.lowercased()
        }
        return sums
    }

    static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    /// The SHA-256 of a file, read in chunks.
    static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads a file to disk, reporting progress (0…1, or nil while the size is unknown).
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var moveError: (any Error)?

    private init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    /// Downloads `url` to `destination` (replaced if present). Throws `.network` on failure and
    /// `CancellationError` when the calling task is cancelled.
    static func download(_ url: URL, to destination: URL, timeout: TimeInterval = 600,
                         progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        let download = FileDownload(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Stow", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.lock.withLock { download.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is gone once this returns, so it's moved here.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.withLock { moveError = StowError.network("HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "the download").") }
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error = error as? URLError, error.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error {
            continuation?.resume(throwing: StowError.network(error.localizedDescription))
        } else if let moveError = lock.withLock({ moveError }) {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume()
        }
    }
}
