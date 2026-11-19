import Foundation

/// yt-dlp writes its cookie jar back on exit, so every run (yt-dlp, or mpv's ytdl_hook) gets a
/// private 0600 copy of cookies.txt in a 0700 `cookie-copies/` folder next to it. Copies are
/// deleted after each run, at launch, at sign-out and at quit.
enum CookieCopy {
    static func directory(for cookiesFile: URL) -> URL {
        cookiesFile.deletingLastPathComponent().appending(path: "cookie-copies", directoryHint: .isDirectory)
    }

    /// Returns a new copy; the caller deletes it. Throws `.notSignedIn` when `cookiesFile` is missing.
    static func make(of cookiesFile: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: cookiesFile.path) else { throw StowError.notSignedIn }
        let directory = directory(for: cookiesFile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let copy = directory.appending(path: "\(UUID().uuidString).txt")
        try FileManager.default.copyItem(at: cookiesFile, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        return copy
    }

    /// Deletes every copy, including ones left by runs that never finished.
    static func removeAll(for cookiesFile: URL) {
        try? FileManager.default.removeItem(at: directory(for: cookiesFile))
    }
}
