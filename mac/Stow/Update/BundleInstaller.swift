import Darwin
import Foundation
import os

enum UpdateError: Error, Equatable, LocalizedError {
    case blocked(String)
    case checksum(String)
    case signature(String)
    case bundle(String)
    case install(String)
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let text), .checksum(let text), .signature(let text), .bundle(let text), .install(let text), .tool(let text): text
        }
    }
}

/// The file steps of an app update: unzip, quarantine, checks, swapping the bundle in place, relaunch.
enum BundleInstaller {
    static let quarantineAttribute = "com.apple.quarantine"

    /// Unzips `zip` (made by `ditto -c -k --keepParent`) into `directory` and returns the one
    /// .app at its top level.
    static func unzip(_ zip: URL, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await UpdateProcess.run(URL(filePath: "/usr/bin/ditto"), ["-x", "-k", zip.path, directory.path])
        guard result.exitCode == 0 else { throw UpdateError.bundle("Couldn't unzip the update: \(result.stderr)") }
        let apps = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw UpdateError.bundle("The update has no app in it.") }
        return app
    }

    /// Removes com.apple.quarantine from `url` and everything inside it.
    static func removeQuarantine(in url: URL) throws {
        for path in allPaths(in: url) {
            if removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                throw UpdateError.install("Couldn't clear the quarantine flag on \(path): \(String(cString: strerror(errno)))")
            }
        }
    }

    static func hasQuarantine(in url: URL) -> Bool {
        allPaths(in: url).contains { getxattr($0, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    }

    private static func allPaths(in url: URL) -> [String] {
        var paths = [url.path]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: []) {
            for case let item as URL in enumerator { paths.append(item.path) }
        }
        return paths
    }

    /// The new app has to be Stow (same bundle id), at the advertised version, and signed like
    /// this copy: `codesign --verify --deep --strict`, then the Security framework against the team.
    static func check(app: URL, bundleIdentifier: String, version: DottedVersion, teamID: String) async throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleIdentifier else {
            throw UpdateError.bundle("The update isn't Stow (bundle id \(Bundle(url: app)?.bundleIdentifier ?? "missing")).")
        }
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let found = shortVersion.flatMap({ DottedVersion($0) }), found == version else {
            throw UpdateError.bundle("The update is version \(shortVersion ?? "unknown"), not \(version).")
        }
        let verify = try await UpdateProcess.run(URL(filePath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path])
        guard verify.exitCode == 0 else {
            throw UpdateError.signature("The update's signature doesn't check out: \(verify.stderr)")
        }
        try CodeSignature.validate(app, teamID: teamID, identifier: bundleIdentifier)
    }

    /// A folder for staging an update on the same volume as `installed`, so the swap is a rename.
    static func stagingDirectory(for installed: URL) throws -> URL {
        do {
            return try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: installed, create: true)
        } catch {
            throw UpdateError.install("Couldn't make a folder for the update: \(error.localizedDescription)")
        }
    }

    /// Whether this process can rename `installed` (it needs write access to the bundle and the
    /// folder it's in).
    static func canReplace(_ installed: URL) -> Bool {
        let manager = FileManager.default
        return manager.isWritableFile(atPath: installed.deletingLastPathComponent().path)
            && manager.isWritableFile(atPath: installed.path)
    }

    /// Puts `replacement` at `installed` and the old bundle at `replacement`'s path, in one atomic
    /// swap when the volume supports it. Either both moves happen or neither: on failure
    /// `installed` is still the old app.
    static func swap(installed: URL, with replacement: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: installed.path) else { throw UpdateError.install("\(installed.path) is missing.") }
        guard manager.fileExists(atPath: replacement.path) else { throw UpdateError.install("\(replacement.path) is missing.") }
        if renamex_np(replacement.path, installed.path, UInt32(RENAME_SWAP)) == 0 { return }
        let swapError = errno
        // No atomic swap here (not APFS, or across volumes): move the old one aside first.
        guard swapError == ENOTSUP || swapError == EINVAL else {
            throw UpdateError.install("Couldn't replace \(installed.lastPathComponent): \(String(cString: strerror(swapError)))")
        }
        let aside = replacement.deletingLastPathComponent().appending(path: "old-" + UUID().uuidString)
        guard rename(installed.path, aside.path) == 0 else {
            throw UpdateError.install("Couldn't move the old \(installed.lastPathComponent) aside: \(String(cString: strerror(errno)))")
        }
        guard rename(replacement.path, installed.path) == 0 else {
            let error = errno
            rename(aside.path, installed.path)
            throw UpdateError.install("Couldn't put the new \(installed.lastPathComponent) in place: \(String(cString: strerror(error)))")
        }
        rename(aside.path, replacement.path)
    }

    /// Starts a helper that waits for process `pid` to exit, opens `app` (with `arguments`, if
    /// any) and deletes `cleanup`. It outlives this process.
    static func spawnRelauncher(pid: Int32, app: URL, cleanup: URL?, arguments: [String]) throws {
        let script = """
        pid=$1; app=$2; cleanup=$3; shift 3
        tries=0
        while kill -0 "$pid" 2>/dev/null && [ $tries -lt 600 ]; do sleep 0.1; tries=$((tries + 1)); done
        if [ $# -gt 0 ]; then /usr/bin/open -n "$app" --args "$@"; else /usr/bin/open -n "$app"; fi
        [ -n "$cleanup" ] && /bin/rm -rf "$cleanup"
        exit 0
        """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "stow-relaunch", String(pid), app.path, cleanup?.path ?? ""] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.install("Couldn't start the relaunch helper: \(error.localizedDescription)")
        }
    }
}

/// Runs a system tool to completion off the main thread.
enum UpdateProcess {
    struct Result: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: Duration = .seconds(120)) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        do {
            try process.run()
        } catch {
            throw UpdateError.tool("Couldn't run \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        // Read both pipes while the tool runs, so a full pipe can't stall it.
        async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        var status: Int32 = -1
        for await code in finished { status = code }
        watchdog.cancel()
        let text = { (data: Data) in String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let result = Result(exitCode: status, stdout: text(await out), stderr: text(await err))
        if timedOut.withLock({ $0 }), status != 0 { throw UpdateError.tool("\(executable.lastPathComponent) timed out.") }
        return result
    }
}
