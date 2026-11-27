import Darwin
import Foundation
import Testing
@testable import Stow

/// Each test works in its own temporary folder.
struct BundleInstallerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "stow-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeApp(at url: URL, marker: String) throws {
        let contents = url.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: contents.appending(path: "Stow"))
    }

    private func marker(of app: URL) -> String? {
        (try? Data(contentsOf: app.appending(path: "Contents/MacOS/Stow"))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func swapPutsTheNewAppInPlaceAndKeepsTheOld() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appending(path: "Applications/Stow.app")
        let staging = root.appending(path: "staging/unzipped/Stow.app")
        try makeApp(at: installed, marker: "old")
        try makeApp(at: staging, marker: "new")

        try BundleInstaller.swap(installed: installed, with: staging)
        #expect(marker(of: installed) == "new")
        #expect(marker(of: staging) == "old")

        // Swapping back is the rollback.
        try BundleInstaller.swap(installed: installed, with: staging)
        #expect(marker(of: installed) == "old")
        #expect(marker(of: staging) == "new")
    }

    @Test func swapWithAMissingUpdateLeavesTheAppAlone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appending(path: "Stow.app")
        try makeApp(at: installed, marker: "old")
        #expect(throws: UpdateError.self) {
            try BundleInstaller.swap(installed: installed, with: root.appending(path: "missing/Stow.app"))
        }
        #expect(marker(of: installed) == "old")
        #expect(throws: UpdateError.self) {
            try BundleInstaller.swap(installed: root.appending(path: "Gone.app"), with: installed)
        }
        #expect(marker(of: installed) == "old")
    }

    @Test func swapIntoAReadOnlyFolderFailsSafely() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "locked").path)
            try? FileManager.default.removeItem(at: root)
        }
        let installed = root.appending(path: "locked/Stow.app")
        let staging = root.appending(path: "staging/Stow.app")
        try makeApp(at: installed, marker: "old")
        try makeApp(at: staging, marker: "new")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.appending(path: "locked").path)
        #expect(!BundleInstaller.canReplace(installed))
        #expect(throws: UpdateError.self) { try BundleInstaller.swap(installed: installed, with: staging) }
        #expect(marker(of: installed) == "old")
        #expect(marker(of: staging) == "new")
    }

    @Test func stagingIsOnTheSameVolume() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appending(path: "Stow.app")
        try makeApp(at: installed, marker: "old")
        let staging = try BundleInstaller.stagingDirectory(for: installed)
        defer { try? FileManager.default.removeItem(at: staging) }
        let volume = { (url: URL) in try url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
        #expect(try volume(staging) == volume(installed))
    }

    @Test func removesQuarantineEverywhere() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Stow.app")
        try makeApp(at: app, marker: "x")
        let value = "0083;00000000;Safari;"
        for path in [app.path, app.appending(path: "Contents/MacOS/Stow").path] {
            #expect(setxattr(path, BundleInstaller.quarantineAttribute, value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0)
        }
        #expect(BundleInstaller.hasQuarantine(in: app))
        try BundleInstaller.removeQuarantine(in: app)
        #expect(!BundleInstaller.hasQuarantine(in: app))
        // Nothing to remove is fine.
        try BundleInstaller.removeQuarantine(in: app)
    }

    @Test func unzipsADittoZip() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "build/Stow.app")
        try makeApp(at: app, marker: "zipped")
        let zip = root.appending(path: "Stow-Mac-0.2.0.zip")
        let made = try await UpdateProcess.run(URL(filePath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", app.path, zip.path])
        #expect(made.exitCode == 0)
        let unzipped = try await BundleInstaller.unzip(zip, into: root.appending(path: "out"))
        #expect(unzipped.lastPathComponent == "Stow.app")
        #expect(marker(of: unzipped) == "zipped")

        let junk = root.appending(path: "junk.zip")
        try Data("not a zip".utf8).write(to: junk)
        await #expect(throws: UpdateError.self) { try await BundleInstaller.unzip(junk, into: root.appending(path: "junk")) }
    }

    /// The test host is a signed Stow.app: a copy of it passes the checks, a changed copy doesn't.
    @Test func checksTheSignatureOfACopyOfThisApp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let running = try CodeSignature.running()
        let teamID = try #require(running.teamID, "the test host isn't signed by a team")
        let version = try #require(DottedVersion.running)
        let identifier = try #require(Bundle.main.bundleIdentifier)
        let copy = root.appending(path: "Stow.app")
        let copied = try await UpdateProcess.run(URL(filePath: "/usr/bin/ditto"), [Bundle.main.bundleURL.path, copy.path])
        #expect(copied.exitCode == 0)
        #expect(try CodeSignature.info(at: copy).teamID == teamID)

        try await BundleInstaller.check(app: copy, bundleIdentifier: identifier, version: version, teamID: teamID)
        await #expect(throws: UpdateError.self) {
            try await BundleInstaller.check(app: copy, bundleIdentifier: identifier, version: version, teamID: "AAAAAAAAAA")
        }
        let next = DottedVersion("\(version.description).1")!
        await #expect(throws: UpdateError.bundle("The update is version \(version), not \(next).")) {
            try await BundleInstaller.check(app: copy, bundleIdentifier: identifier, version: next, teamID: teamID)
        }
        await #expect(throws: UpdateError.self) {
            try await BundleInstaller.check(app: copy, bundleIdentifier: "dev.stow.other", version: version, teamID: teamID)
        }

        // A changed resource breaks the seal.
        let resources = copy.appending(path: "Contents/Resources")
        try Data("tampered".utf8).write(to: resources.appending(path: "extra.txt"))
        await #expect(throws: UpdateError.self) {
            try await BundleInstaller.check(app: copy, bundleIdentifier: identifier, version: version, teamID: teamID)
        }
    }

    @Test func toolLocatorPrefersStowsOwnCopy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appending(path: "bin")
        let homebrew = root.appending(path: "homebrew")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homebrew, withIntermediateDirectories: true)
        let brewed = homebrew.appending(path: "yt-dlp")
        try Data("#!/bin/sh\n".utf8).write(to: brewed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brewed.path)

        #expect(try ToolLocator.url(for: "yt-dlp", ownDirectory: own, searchDirectories: [homebrew.path]) == brewed)
        let mine = own.appending(path: "yt-dlp")
        try Data("#!/bin/sh\n".utf8).write(to: mine)
        // Not executable yet: still Homebrew's.
        #expect(try ToolLocator.url(for: "yt-dlp", ownDirectory: own, searchDirectories: [homebrew.path]) == brewed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mine.path)
        #expect(try ToolLocator.url(for: "yt-dlp", ownDirectory: own, searchDirectories: [homebrew.path]) == mine)
        #expect(throws: StowError.toolNotFound("mpv")) {
            try ToolLocator.url(for: "mpv", ownDirectory: own, searchDirectories: [homebrew.path])
        }
    }
}
