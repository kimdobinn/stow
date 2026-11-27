import Foundation
import Observation
import os

/// A version like "0.1.0", compared number by number (0.10 is after 0.9; 0.1 is 0.1.0).
/// A leading "v" and a suffix after "-" or "+" ("0.2.0-beta") are ignored.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        if let suffix = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = core[..<suffix] }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A release as GitHub's REST API lists it (only what the update check reads).
public struct GitHubRelease: Decodable, Sendable, Equatable {
    public struct Asset: Decodable, Sendable, Equatable {
        public var name: String
        public var browserDownloadURL: URL
        public var size: Int?

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var name: String?
    public var body: String?
    public var draft: Bool
    public var prerelease: Bool
    public var htmlURL: URL
    public var publishedAt: Date?
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

/// A newer (or the newest) iPhone release: what the update sheet shows and installs.
public struct AppUpdate: Codable, Sendable, Equatable, Identifiable {
    /// "0.1.1".
    public var version: String
    public var tag: String
    /// The release's notes (GitHub's Markdown, as written).
    public var notes: String
    /// The release's page on GitHub.
    public var pageURL: URL
    /// Stow-<version>.ipa, for SideStore or AltStore to install.
    public var ipaURL: URL?
    public var ipaSize: Int?
    public var publishedAt: Date?

    public var id: String { tag }
    public var appVersion: AppVersion? { AppVersion(version) }

    public init(version: String, tag: String, notes: String, pageURL: URL, ipaURL: URL?, ipaSize: Int? = nil, publishedAt: Date? = nil) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.pageURL = pageURL
        self.ipaURL = ipaURL
        self.ipaSize = ipaSize
        self.publishedAt = publishedAt
    }

    /// Newer than the installed version (false when either can't be read).
    public func isNewer(than installed: String) -> Bool {
        guard let mine = AppVersion(installed), let theirs = appVersion else { return false }
        return theirs > mine
    }
}

/// Where Stow for iPhone is released, and how to read and install a release. `ios/release.sh`
/// publishes each version as the GitHub pre-release ios-v<version> with Stow-<version>.ipa; the
/// same repository has Android's releases (v*) and the Mac's (mac-v*), which don't count here.
public enum Updates {
    /// Newest first. 100 a page (GitHub's most), so the Android and Mac releases don't push the
    /// iPhone's off the first page.
    public static let releasesURL = URL(string: "https://api.github.com/repos/kimdobinn/stow/releases?per_page=100")!
    public static let tagPrefix = "ios-v"
    public static let releasesPage = URL(string: "https://github.com/kimdobinn/stow/releases")!

    public static func decode(_ data: Data) throws -> [GitHubRelease] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    }

    /// The version in an iPhone release's tag ("ios-v0.1.1" → 0.1.1); nil for other tags.
    public static func version(ofTag tag: String) -> AppVersion? {
        guard tag.hasPrefix(tagPrefix) else { return nil }
        return AppVersion(String(tag.dropFirst(tagPrefix.count)))
    }

    /// The newest iPhone release: published (not a draft), tagged ios-v<version>, highest version.
    /// Pre-releases count (every iPhone release is one).
    public static func latest(in releases: [GitHubRelease]) -> AppUpdate? {
        let candidates = releases.compactMap { release -> (AppVersion, GitHubRelease)? in
            guard !release.draft, let version = version(ofTag: release.tagName) else { return nil }
            return (version, release)
        }
        // max(by:) keeps the first of equal versions: GitHub lists the newest first.
        guard let (version, release) = candidates.reversed().max(by: { $0.0 < $1.0 }) else { return nil }
        let tagVersion = String(release.tagName.dropFirst(tagPrefix.count))
        let ipa = ipaAsset(in: release, version: tagVersion)
        return AppUpdate(version: version.description, tag: release.tagName,
                         notes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                         pageURL: release.htmlURL, ipaURL: ipa?.browserDownloadURL, ipaSize: ipa?.size,
                         publishedAt: release.publishedAt)
    }

    /// The app in a release: Stow-<version>.ipa, else any .ipa.
    public static func ipaAsset(in release: GitHubRelease, version: String) -> GitHubRelease.Asset? {
        release.assets.first { $0.name == "Stow-\(version).ipa" }
            ?? release.assets.first { $0.name.lowercased().hasSuffix(".ipa") }
    }

    /// Who installs an update.
    public enum Installer: Sendable, Equatable {
        case sideStore, altStore, browser
    }

    /// SideStore's and AltStore's deep link that installs an .ipa from a URL (both handle the
    /// host "install" with a "url" query item: SideStore in SideStore/DeepLinks/URLHandler.swift,
    /// AltStore in AltStore/SceneDelegate.swift).
    public static func installLink(scheme: String, ipa: URL) -> URL {
        // Everything but letters, digits and -._~:/ is encoded, so an "&", "=" or "+" in the ipa's
        // URL stays part of it (they read it back with URLComponents.queryItems, which decodes).
        var allowed = CharacterSet(charactersIn: "-._~:/")
        allowed.formUnion(CharacterSet(charactersIn: "a"..."z"))
        allowed.formUnion(CharacterSet(charactersIn: "A"..."Z"))
        allowed.formUnion(CharacterSet(charactersIn: "0"..."9"))
        let value = ipa.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ipa.absoluteString
        return URL(string: "\(scheme)://install?url=\(value)")!
    }

    /// What "Update" opens: SideStore's install link, else AltStore's, else the release page.
    /// `canOpen` is UIApplication.canOpenURL (the schemes are in LSApplicationQueriesSchemes).
    public static func link(for update: AppUpdate, canOpen: (URL) -> Bool) -> (url: URL, installer: Installer) {
        if let ipa = update.ipaURL {
            if canOpen(URL(string: "sidestore://")!) { return (installLink(scheme: "sidestore", ipa: ipa), .sideStore) }
            if canOpen(URL(string: "altstore://")!) { return (installLink(scheme: "altstore", ipa: ipa), .altStore) }
        }
        return (update.pageURL, .browser)
    }
}

/// Checks GitHub for a newer iPhone release: at most once a day (`checkIfDue`, at launch, when
/// the app comes back and in the background refresh) and when asked (`check`, Settings). It
/// remembers the newest release it found, so the update shows again after a relaunch without
/// asking GitHub, and which version's banner was dismissed.
@MainActor
@Observable
public final class UpdateChecker {
    public enum Status: Equatable, Sendable {
        case idle, checking, checked
        case failed(String)
    }

    /// The installed version (CFBundleShortVersionString).
    public let currentVersion: String
    public private(set) var status: Status = .idle
    /// The newest iPhone release found by the last check that worked (maybe the installed one).
    public private(set) var latest: AppUpdate?
    /// When a check last worked.
    public private(set) var lastChecked: Date?
    /// The version whose banner was closed ("Not now" or the banner's close button).
    public private(set) var dismissedVersion: String?

    public static let interval: TimeInterval = 24 * 60 * 60
    /// After a failed check, how long the automatic checks wait (asking in Settings doesn't).
    public static let retryInterval: TimeInterval = 60 * 60

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var lastFailure: Date?
    @ObservationIgnored private let log = Logger(subsystem: "dev.stow.ios", category: "updates")

    public init(currentVersion: String, url: URL = Updates.releasesURL, session: URLSession? = nil,
                defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.url = url
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.waitsForConnectivity = false
            return URLSession(configuration: configuration)
        }()
        self.defaults = defaults
        self.now = now
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        latest = defaults.data(forKey: Keys.latest).flatMap { try? JSONDecoder().decode(AppUpdate.self, from: $0) }
        dismissedVersion = defaults.string(forKey: Keys.dismissed)
        if lastChecked != nil { status = .checked }
    }

    /// A release newer than this app, when there is one.
    public var available: AppUpdate? {
        guard let latest, latest.isNewer(than: currentVersion) else { return nil }
        return latest
    }

    /// The one-line hint outside Settings: an update whose banner wasn't closed.
    public var showsBanner: Bool {
        guard let available else { return false }
        return available.version != dismissedVersion
    }

    public func dismissBanner() {
        guard let available else { return }
        dismissedVersion = available.version
        defaults.set(available.version, forKey: Keys.dismissed)
    }

    /// A day since the last check (or never checked, or the clock went back), and no failure in the last hour.
    public var isDue: Bool {
        let time = now()
        if let lastFailure, time.timeIntervalSince(lastFailure) < Self.retryInterval, time >= lastFailure { return false }
        guard let lastChecked else { return true }
        let age = time.timeIntervalSince(lastChecked)
        return age >= Self.interval || age < 0
    }

    /// The automatic check: only when it's due.
    public func checkIfDue() async {
        guard isDue else { return }
        await check()
    }

    /// Asks GitHub now (joining a check under way).
    public func check() async {
        if let inFlight { return await inFlight.value }
        status = .checking
        let task = Task { await self.fetch() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func fetch() async {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Stow-iOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw CheckError.http(code) }
            let releases = try Updates.decode(data)
            let newest = Updates.latest(in: releases)
            latest = newest
            if let newest, let data = try? JSONEncoder().encode(newest) {
                defaults.set(data, forKey: Keys.latest)
            } else {
                defaults.removeObject(forKey: Keys.latest)
            }
            let time = now()
            lastChecked = time
            lastFailure = nil
            defaults.set(time, forKey: Keys.lastChecked)
            status = .checked
            log.info("Checked for updates: newest \(newest?.version ?? "none", privacy: .public), installed \(self.currentVersion, privacy: .public)")
        } catch {
            lastFailure = now()
            status = .failed(Self.message(for: error))
            log.error("Update check failed: \(String(describing: error), privacy: .public)")
        }
    }

    enum CheckError: Error {
        case http(Int)
    }

    static func message(for error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "No internet connection"
            case .timedOut: return "GitHub didn't answer"
            default: return "Couldn't reach GitHub"
            }
        }
        if case CheckError.http(let code) = error {
            return code == 403 || code == 429 ? "GitHub is busy. Try again later" : "GitHub answered with error \(code)"
        }
        if error is DecodingError { return "Couldn't read GitHub's answer" }
        return "Couldn't check for updates"
    }

    enum Keys {
        static let lastChecked = "updates.lastChecked"
        static let latest = "updates.latest"
        static let dismissed = "updates.dismissedVersion"
    }
}
