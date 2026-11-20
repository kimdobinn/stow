import Foundation

/// Files in ~/Library/Application Support/Stow.
enum AppPaths {
    static let supportDirectory: URL = URL.applicationSupportDirectory.appending(path: "Stow", directoryHint: .isDirectory)

    static let settingsFile = supportDirectory.appending(path: "settings.json")
    static let stateFile = supportDirectory.appending(path: "state.json")
    static let logFile = supportDirectory.appending(path: "log.json")
    /// Netscape cookies.txt for yt-dlp --cookies. Written by Account, read by YouTube.
    static let cookiesFile = supportDirectory.appending(path: "cookies.txt")
    /// The Firebase project's service-account key (copied in from the Phone tab).
    static let firebaseKeyFile = supportDirectory.appending(path: "firebase-key.json")
    /// Encrypts what only paired phones may read; shared with them through the pairing QR code.
    static let pairingKeyFile = supportDirectory.appending(path: "pairing-key")

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
