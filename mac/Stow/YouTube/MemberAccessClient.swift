import Foundation

/// Whether the saved sign-in's membership level can watch a members-only video: yt-dlp looks the
/// video up with the cookies, and YouTube either serves it or names the level it needs.
struct MemberAccessClient: Sendable {
    let ytdlp: YTDLP

    func access(videoId: String, cookiesFile: URL) async throws -> MemberAccess {
        let cookies = try CookieCopy.make(of: cookiesFile)
        defer { try? FileManager.default.removeItem(at: cookies) }
        do {
            let output = try await ytdlp.run(["--no-warnings", "--cookies", cookies.path, "-J", "--skip-download", "--no-playlist",
                                              "--", "https://www.youtube.com/watch?v=\(videoId)"], timeout: .seconds(60))
            return Self.access(fromLookup: output.stdout)
        } catch StowError.processFailed(_, _, let stderr) {
            if let access = Self.access(fromError: stderr) { return access }
            throw StowError.processFailed(tool: "yt-dlp", exitCode: 1, stderr: stderr)
        }
    }

    /// A video that plays: still for members, or public now (members-first videos open up later).
    static func access(fromLookup json: Data) -> MemberAccess {
        let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        switch object?["availability"] as? String {
        case "public", "unlisted": return .nowPublic
        default: return .watchable
        }
    }

    /// What a failed lookup says about access: the level a locked video needs, or (when it failed
    /// only after YouTube let the account in, picking a stream) watchable. Nil when it can't tell.
    static func access(fromError text: String) -> MemberAccess? {
        if let range = text.range(of: "members on level: ") {
            let rest = text[range.upperBound...]
            let end = rest.range(of: " (or any higher level)")?.lowerBound ?? rest.firstIndex(where: { $0 == "." || $0.isNewline }) ?? rest.endIndex
            let level = rest[..<end].trimmingCharacters(in: .whitespaces)
            return .locked(level: level.isEmpty ? nil : level)
        }
        let lowered = text.lowercased()
        // A members-only video the account can't see at all (YouTube says this to non-members, and
        // for videos taken down): either way, not one it can watch.
        if lowered.contains("join this channel to get access") || lowered.contains("members-only content")
            || lowered.contains("this video is not available") || lowered.contains("video unavailable") {
            return .locked(level: nil)
        }
        if lowered.contains("requested format is not available") || lowered.contains("only images are available") {
            return .watchable
        }
        return nil
    }
}
