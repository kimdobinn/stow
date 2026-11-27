import Foundation

/// Finds command-line tools by absolute path; GUI apps don't inherit the shell PATH.
enum ToolLocator {
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// PATH for child processes, so tools can find their own helpers (yt-dlp → ffmpeg, deno).
    static let childPath = (searchDirectories + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")

    /// Stow's own copy (AppPaths.binDirectory, e.g. the yt-dlp it keeps current) when it's there,
    /// else the first one in `searchDirectories`. Stow's copy is only put in place after it ran,
    /// and removed at launch if it no longer runs. Throws `StowError.toolNotFound`.
    static func url(for tool: String) throws -> URL {
        try url(for: tool, ownDirectory: AppPaths.binDirectory)
    }

    static func url(for tool: String, ownDirectory: URL?, searchDirectories: [String] = searchDirectories) throws -> URL {
        let own = ownDirectory.map { [$0.path] } ?? []
        for directory in own + searchDirectories {
            let url = URL(filePath: directory).appending(path: tool)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw StowError.toolNotFound(tool)
    }
}
