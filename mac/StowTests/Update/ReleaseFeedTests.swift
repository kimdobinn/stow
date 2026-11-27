import Foundation
import Testing
@testable import Stow

struct ReleaseFeedTests {
    static func release(_ tag: String, draft: Bool = false, prerelease: Bool = true, body: String = "",
                        assets: [String]) -> String {
        let list = assets.map { name in
            #"{"name": "\#(name)", "size": 123, "browser_download_url": "https://github.com/kimdobinn/stow/releases/download/\#(tag)/\#(name)"}"#
        }.joined(separator: ",")
        let escaped = body.replacingOccurrences(of: "\n", with: "\\n")
        return #"""
        {"tag_name": "\#(tag)", "name": "Stow \#(tag)", "body": "\#(escaped)", "draft": \#(draft), "prerelease": \#(prerelease),
         "published_at": "2026-11-27T03:32:35Z", "html_url": "https://example.com", "assets": [\#(list)]}
        """#
    }

    static let sha = String(repeating: "ab", count: 32)

    static let feed = "[" + [
        release("v0.8.1", prerelease: false, assets: ["Stow-0.8.1.apk"]),
        release("ios-v0.1.0", assets: ["Stow-0.1.0.ipa"]),
        release("mac-v0.9.0", draft: true, assets: ["Stow-Mac-0.9.0.zip"]),
        release("mac-v0.3.0", assets: ["notes.txt"]),
        release("mac-v0.2.0", body: "- Updates itself\n- Keeps yt-dlp current\n\nSHA-256: \(sha)",
                assets: ["Stow-Mac-0.2.0.zip", "Stow-Mac-0.2.0.zip.sha256"]),
        release("mac-v0.10.0-beta", assets: ["Stow-Mac-0.10.0.zip"]),
        release("mac-v0.1.0", assets: ["Stow-Mac-0.1.0.zip"]),
    ].joined(separator: ",") + "]"

    @Test func picksTheNewestMacRelease() throws {
        let releases = try GitHubRelease.decodeList(Data(Self.feed.utf8))
        #expect(releases.count == 7)
        let newest = try #require(MacRelease.newest(in: releases))
        // Not the Android/iPhone tags, not the draft, not the one without a zip, not a bad version.
        #expect(newest.version == DottedVersion("0.2.0"))
        #expect(newest.tag == "mac-v0.2.0")
        #expect(newest.zipURL.lastPathComponent == "Stow-Mac-0.2.0.zip")
        #expect(newest.zipSize == 123)
        #expect(newest.sha256 == Self.sha)
        #expect(newest.sha256URL?.lastPathComponent == "Stow-Mac-0.2.0.zip.sha256")
        #expect(newest.notes == "- Updates itself\n- Keeps yt-dlp current")
        #expect(newest.publishedAt == Date(timeIntervalSince1970: 1_795_750_355))
    }

    @Test func comparesNumericallyAcrossReleases() throws {
        let feed = "[" + [Self.release("mac-v0.9.0", assets: ["Stow-Mac-0.9.0.zip"]),
                          Self.release("mac-v0.10.0", assets: ["Stow-Mac-0.10.0.zip"])].joined(separator: ",") + "]"
        #expect(MacRelease.newest(in: try GitHubRelease.decodeList(Data(feed.utf8)))?.version == DottedVersion("0.10.0"))
    }

    @Test func noMacReleaseYet() throws {
        let feed = "[" + Self.release("v0.8.1", prerelease: false, assets: ["Stow-0.8.1.apk"]) + "]"
        #expect(MacRelease.newest(in: try GitHubRelease.decodeList(Data(feed.utf8))) == nil)
        #expect(MacRelease.newest(in: try GitHubRelease.decodeList(Data("[]".utf8))) == nil)
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: StowError.self) { try GitHubRelease.decodeList(Data(#"{"message": "API rate limit exceeded"}"#.utf8)) }
    }

    @Test func checksumInNotes() {
        #expect(MacRelease.checksum(inNotes: "SHA-256: \(Self.sha.uppercased())") == Self.sha)
        #expect(MacRelease.checksum(inNotes: "x\nsha256: `\(Self.sha)`\n") == Self.sha)
        #expect(MacRelease.checksum(inNotes: "SHA-256: abc") == nil)
        #expect(MacRelease.checksum(inNotes: "- Fixed SHA-256 handling") == nil)
    }

    @Test func parsesYtDlpsLatestRelease() throws {
        let json = Self.release("2026.11.23", prerelease: false,
                           assets: ["yt-dlp", "yt-dlp_macos", "yt-dlp_macos.zip", "SHA2-256SUMS", "SHA2-512SUMS"])
        let parsed = try #require(YtDlpRelease(release: GitHubRelease.decodeOne(Data(json.utf8))))
        #expect(parsed.version == DottedVersion("2026.11.23"))
        #expect(parsed.binaryURL.lastPathComponent == "yt-dlp_macos")
        #expect(parsed.checksumsURL.lastPathComponent == "SHA2-256SUMS")
        let noBinary = Self.release("2026.11.23", prerelease: false, assets: ["yt-dlp", "SHA2-256SUMS"])
        #expect(YtDlpRelease(release: try GitHubRelease.decodeOne(Data(noBinary.utf8))) == nil)
    }

    @MainActor
    @Test func appUpdaterChecksAFeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = directory.appending(path: "releases.json")
        try Data(Self.feed.utf8).write(to: feed)

        let older = AppUpdater(feedURL: feed, currentVersion: DottedVersion("0.1.0"), defaults: nil)
        await older.checkNow()
        #expect(older.availableRelease?.version == DottedVersion("0.2.0"))
        #expect(older.lastChecked != nil)

        let same = AppUpdater(feedURL: feed, currentVersion: DottedVersion("0.2"), defaults: nil)
        await same.checkNow()
        #expect(same.status == .upToDate)

        let missing = AppUpdater(feedURL: directory.appending(path: "nothing.json"), currentVersion: DottedVersion("0.1.0"), defaults: nil)
        await missing.checkNow()
        guard case .failed = missing.status else { Issue.record("expected a failed check, got \(missing.status)"); return }
    }

    @MainActor
    @Test func appUpdaterWaitsForTheAlarm() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = directory.appending(path: "releases.json")
        try Data(Self.feed.utf8).write(to: feed)
        let app = directory.appending(path: "Stow.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        var terminated = false
        let updater = AppUpdater(feedURL: feed, bundleURL: app, currentVersion: DottedVersion("0.1.0"), defaults: nil,
                                 blocker: { .alarmRunning }, terminate: { terminated = true })
        await updater.checkNow()
        #expect(await updater.install() == false)
        #expect(updater.installError == "The alarm is running. Update after it ends.")
        #expect(updater.installPhase == nil)
        #expect(!terminated)
        #expect(FileManager.default.fileExists(atPath: app.path))
    }

    @MainActor
    @Test func remembersTheLastCheckForADay() async throws {
        let suite = "stow-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = directory.appending(path: "releases.json")
        try Data(Self.feed.utf8).write(to: feed)

        await AppUpdater(feedURL: feed, currentVersion: DottedVersion("0.1.0"), defaults: defaults).checkNow()
        // The next launch shows what the last check found without asking GitHub again.
        let relaunched = AppUpdater(feedURL: feed, currentVersion: DottedVersion("0.1.0"), defaults: defaults)
        #expect(relaunched.availableRelease?.version == DottedVersion("0.2.0"))
        #expect(!DailyCheck.isDue(lastChecked: relaunched.lastChecked))
        // Once updated, the remembered release is no longer offered.
        #expect(AppUpdater(feedURL: feed, currentVersion: DottedVersion("0.2.0"), defaults: defaults).status == .upToDate)
    }
}
