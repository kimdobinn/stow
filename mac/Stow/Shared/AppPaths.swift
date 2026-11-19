import Foundation

/// Files in ~/Library/Application Support/Stow.
enum AppPaths {
    static let supportDirectory: URL = URL.applicationSupportDirectory.appending(path: "Stow", directoryHint: .isDirectory)

    static let settingsFile = supportDirectory.appending(path: "settings.json")
    static let stateFile = supportDirectory.appending(path: "state.json")
    static let logFile = supportDirectory.appending(path: "log.json")
    /// Netscape cookies.txt for yt-dlp --cookies. Written by Account, read by YouTube.
    static let cookiesFile = supportDirectory.appending(path: "cookies.txt")

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
