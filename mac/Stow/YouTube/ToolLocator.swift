import Foundation

/// Finds command-line tools by absolute path; GUI apps don't inherit the shell PATH.
enum ToolLocator {
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// PATH for child processes, so tools can find their own helpers (yt-dlp → ffmpeg).
    static let childPath = (searchDirectories + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")

    /// Throws `StowError.toolNotFound`.
    static func url(for tool: String) throws -> URL {
        for directory in searchDirectories {
            let url = URL(filePath: directory).appending(path: tool)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw StowError.toolNotFound(tool)
    }
}
