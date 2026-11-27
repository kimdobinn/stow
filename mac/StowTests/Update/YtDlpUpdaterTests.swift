import Foundation
import Testing
@testable import Stow

struct YtDlpUpdaterTests {
    @Test func parsesSHA256Sums() {
        let a = String(repeating: "a", count: 64)
        let b = String(repeating: "B", count: 64)
        let text = """
        \(a)  yt-dlp
        \(b) *yt-dlp_macos
        not a checksum line
        1234  yt-dlp_linux

        \(a)  yt-dlp_macos.zip
        """
        let sums = SHA256Sums.parse(text)
        #expect(sums == ["yt-dlp": a, "yt-dlp_macos": b.lowercased(), "yt-dlp_macos.zip": a])
        #expect(SHA256Sums.parse("") == [:])
    }

    @Test func hashesAFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "stow-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try SHA256Sums.digest(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func readsTheVersionOfABinary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appending(path: "yt-dlp")
        try Data("#!/bin/sh\necho 2026.11.23\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        #expect(try await YtDlpUpdater.version(of: fake) == DottedVersion("2026.11.23"))

        try Data("#!/bin/sh\necho broken >&2\nexit 3\n".utf8).write(to: fake)
        await #expect(throws: UpdateError.self) { try await YtDlpUpdater.version(of: fake) }
    }

    @MainActor
    @Test func aCopyThatDoesntRunIsRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let updater = YtDlpUpdater(directory: directory, defaults: nil)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: updater.binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: updater.binary.path)
        await updater.validateInstalled()
        #expect(updater.installedVersion == nil)
        #expect(!FileManager.default.fileExists(atPath: updater.binary.path))
        #expect(updater.lastError?.hasPrefix("Stow's yt-dlp didn't run") == true)
    }

    @MainActor
    @Test func waitsForTheAlarm() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // The URL is never fetched: the alarm blocks first.
        let updater = YtDlpUpdater(directory: directory, latestURL: URL(string: "https://invalid.example")!, defaults: nil,
                                   blocker: { .alarmRunning })
        await updater.update()
        #expect(updater.lastError == "Waiting for the alarm to end.")
        #expect(updater.lastChecked == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func commitReplacesTheBinaryInOneRename() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "yt-dlp")
        let staged = directory.appending(path: "yt-dlp.download")
        try Data("old".utf8).write(to: binary)
        try Data("new".utf8).write(to: staged)
        try YtDlpUpdater.commit(staged, to: binary)
        #expect(try String(contentsOf: binary, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(throws: UpdateError.self) { try YtDlpUpdater.commit(staged, to: binary) }
    }

    /// The real yt-dlp release from GitHub into a temporary folder.
    /// Run with TEST_RUNNER_STOW_NETWORK_TESTS=1 xcodebuild test.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STOW_NETWORK_TESTS"] != nil), .timeLimit(.minutes(5)))
    func installsTheRealLatestRelease() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-ytdlp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var logs: [String] = []
        let updater = YtDlpUpdater(directory: directory, defaults: nil, log: { logs.append($1) })
        await updater.update()
        #expect(updater.lastError == nil)
        let release = try await YtDlpUpdater.latestRelease(from: UpdateEndpoints.ytDlpLatest)
        #expect(updater.installedVersion == release.version)
        #expect(FileManager.default.isExecutableFile(atPath: updater.binary.path))
        #expect(!BundleInstaller.hasQuarantine(in: updater.binary))
        #expect(try ToolLocator.url(for: "yt-dlp", ownDirectory: directory) == updater.binary)
        #expect(logs.contains("Installed yt-dlp \(release.version) for Stow."))
        print("yt-dlp \(release.version) installed at \(updater.binary.path)")

        // Already current: nothing is downloaded again.
        let modified = try FileManager.default.attributesOfItem(atPath: updater.binary.path)[.modificationDate] as? Date
        await updater.update()
        #expect(try FileManager.default.attributesOfItem(atPath: updater.binary.path)[.modificationDate] as? Date == modified)
        // A fresh launch finds and runs it.
        let relaunched = YtDlpUpdater(directory: directory, defaults: nil)
        await relaunched.validateInstalled()
        #expect(relaunched.installedVersion == release.version)
    }
}
