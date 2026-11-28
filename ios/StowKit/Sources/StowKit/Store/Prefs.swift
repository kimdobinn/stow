import Foundation
import Observation

/// Pairing (from the Mac's QR code) and settings, in UserDefaults. Observable, so views follow changes.
@MainActor
@Observable
public final class Prefs {
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wifiOnly = defaults.object(forKey: Keys.wifiOnly) as? Bool ?? true
        downloadSort = defaults.string(forKey: Keys.sort).flatMap(DownloadSort.init(rawValue:)) ?? .recentlyDownloaded
        groupByChannel = defaults.bool(forKey: Keys.group)
        quality = (defaults.string(forKey: Keys.quality).flatMap(DownloadQuality.init(rawValue:)) ?? .p1080).supported
        autoplay = defaults.bool(forKey: Keys.autoplay)
        calm = defaults.bool(forKey: Keys.calm)
        grayscale = defaults.bool(forKey: Keys.grayscale)
        theme = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
        let speed = defaults.double(forKey: Keys.speed)
        playbackSpeed = Self.playbackSpeeds.contains(speed) ? speed : 1
        recentSearches = (defaults.stringArray(forKey: Keys.recentSearches) ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        watchedHere = Set(defaults.stringArray(forKey: Keys.watchedHere) ?? [])
    }

    /// Download only on Wi-Fi (default) or also on mobile data.
    public private(set) var wifiOnly: Bool
    /// Use `Repository.setWifiOnly`, which also re-checks the waiting downloads.
    public func setWifiOnly(_ on: Bool) { wifiOnly = on; defaults.set(on, forKey: Keys.wifiOnly) }

    public var downloadSort: DownloadSort { didSet { defaults.set(downloadSort.rawValue, forKey: Keys.sort) } }
    public var groupByChannel: Bool { didSet { defaults.set(groupByChannel, forKey: Keys.group) } }

    /// The highest resolution a download takes (less when the video has nothing that high).
    /// Only `DownloadQuality.available` qualities stick; others fall back to the best available.
    public var downloadQuality: DownloadQuality {
        get { quality }
        set {
            quality = newValue.supported
            defaults.set(quality.rawValue, forKey: Keys.quality)
        }
    }
    private var quality: DownloadQuality

    /// Play the next video when one ends (off: stop with a "done" screen).
    public var autoplay: Bool { didSet { defaults.set(autoplay, forKey: Keys.autoplay) } }
    /// Titles only: no thumbnails anywhere.
    public var calm: Bool { didSet { defaults.set(calm, forKey: Keys.calm) } }
    /// The app in black and white (not the video itself).
    public var grayscale: Bool { didSet { defaults.set(grayscale, forKey: Keys.grayscale) } }
    /// How the app looks: following the phone, light, dark or warm paper.
    public var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }

    public static let playbackSpeeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    /// The player's speed, kept between videos and launches.
    public var playbackSpeed: Double { didSet { defaults.set(playbackSpeed, forKey: Keys.speed) } }

    // Recent searches

    /// What you searched YouTube for, latest first (at most 20).
    public private(set) var recentSearches: [String]

    public func addRecentSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !q.isEmpty else { return }
        let rest = recentSearches.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        saveRecentSearches(Array(([q] + rest).prefix(Self.recentSearchLimit)))
    }

    public func removeRecentSearch(_ query: String) { saveRecentSearches(recentSearches.filter { $0 != query }) }

    public func clearRecentSearches() { saveRecentSearches([]) }

    static let recentSearchLimit = 20

    private func saveRecentSearches(_ list: [String]) {
        recentSearches = list
        defaults.set(list, forKey: Keys.recentSearches)
    }

    // Watched here

    /// Videos marked watched on the phone that were never sent to it (streamed).
    public private(set) var watchedHere: Set<String>

    public func setWatchedHere(_ id: String, _ watched: Bool) {
        if watched { watchedHere.insert(id) } else { watchedHere.remove(id) }
        defaults.set(watchedHere.sorted(), forKey: Keys.watchedHere)
    }

    // Pairing

    /// The Firebase project the Mac paired this phone with, once paired.
    public var pairedProject: String? { defaults.string(forKey: Keys.project) }

    /// Decrypts what only paired phones may read (the YouTube cookies and feeds).
    public var pairingKey: Data? { defaults.string(forKey: Keys.key).flatMap(Data.init(base64URLEncoded:)) }

    public func savePairing(projectId: String, keyBase64URL: String) {
        defaults.set(projectId, forKey: Keys.project)
        defaults.set(keyBase64URL, forKey: Keys.key)
    }

    public func clearPairing() {
        defaults.removeObject(forKey: Keys.project)
        defaults.removeObject(forKey: Keys.key)
    }

    // Mode

    /// "mac" or "standalone"; nil until chosen (see `AppMode.resolve`).
    public var appMode: String? {
        get { defaults.string(forKey: Keys.appMode) }
        set { defaults.set(newValue, forKey: Keys.appMode) }
    }

    /// The mode for this launch, from the preferences only (never Firebase). A paired install from
    /// before modes existed becomes "mac" here, and stays paired.
    public func resolveMode() -> AppMode {
        let resolved = AppMode.resolve(stored: appMode, hasPairing: pairedProject != nil)
        if let write = resolved.write { appMode = write }
        return resolved.mode
    }

    /// Standalone: the Home banner after YouTube signed the phone out was closed (until the next time).
    public var expiredBannerClosed: Bool {
        get { defaults.bool(forKey: Keys.expiredBannerClosed) }
        set { defaults.set(newValue, forKey: Keys.expiredBannerClosed) }
    }

    /// Standalone, after switching from the Mac: Home suggests signing in to YouTube here, once.
    public var signInPromptPending: Bool {
        get { defaults.bool(forKey: Keys.signInPrompt) }
        set { defaults.set(newValue, forKey: Keys.signInPrompt) }
    }

    // yt-dlp

    /// When the app last updated yt-dlp (YouTube changes often).
    public var lastYtDlpUpdate: Date? {
        get { defaults.object(forKey: Keys.ytDlpUpdate) as? Date }
        set { defaults.set(newValue, forKey: Keys.ytDlpUpdate) }
    }

    enum Keys {
        static let wifiOnly = "wifiOnly"
        static let project = "pairedProject"
        static let key = "pairingKey"
        static let ytDlpUpdate = "lastYtDlpUpdate"
        static let sort = "downloadSort"
        static let autoplay = "autoplay"
        static let calm = "calm"
        static let grayscale = "grayscale"
        static let watchedHere = "watchedHere"
        static let group = "groupByChannel"
        static let theme = "theme"
        static let quality = "downloadQuality"
        static let recentSearches = "recentSearches"
        static let speed = "playbackSpeed"
        static let appMode = "appMode"
        static let expiredBannerClosed = "standaloneExpiredBannerClosed"
        static let signInPrompt = "standaloneSignInPrompt"
    }
}

/// Demo mode: sample channels and feeds instead of Firebase (downloads and YouTube stay real).
public enum Demo {
    /// On with the `-demo` launch argument or a file named "demo" in Application Support.
    public static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments,
                                 directory: URL = StowPaths.applicationSupport) -> Bool {
        arguments.contains("-demo") || FileManager.default.fileExists(atPath: directory.appending(path: "demo").path)
    }

    /// Debug builds: standalone mode asked for with `-standalone` or a file named "standalone"
    /// in Application Support (ignored when paired, and when demo mode is on).
    public static func wantsStandalone(arguments: [String] = ProcessInfo.processInfo.arguments,
                                       directory: URL = StowPaths.applicationSupport) -> Bool {
        arguments.contains("-standalone") || FileManager.default.fileExists(atPath: directory.appending(path: "standalone").path)
    }
}

/// Where StowKit keeps its files.
public enum StowPaths {
    public static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
