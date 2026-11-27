import Foundation

/// Thin wrapper over the yt-dlp binary.
struct YTDLP: Sendable {
    enum Failure: Equatable {
        /// Cookies missing, invalid or rotated; YouTube wants a sign-in.
        case auth
        /// The video or playlist doesn't exist or can't be viewed.
        case unavailable
        case network
        case other
    }

    /// Keeps the user's yt-dlp config from changing the output format.
    private static let baseArguments = ["--ignore-config", "--no-progress"] + youTubeWorkaround + approximateDates

    /// Flat listings (YouTube's Home and Subscriptions, channel tabs) have no dates unless asked:
    /// this turns YouTube's "3 days ago" into an approximate timestamp.
    static let approximateDates = ["--extractor-args", "youtubetab:approximate_date"]

    /// Has yt-dlp read YouTube's TV player script: with yt-dlp 2026.10.26 the challenge solver
    /// fails on the default script whenever you're signed in (no playable formats, so members-only
    /// videos wouldn't play), and works on this one. Drop it once a newer yt-dlp is installed.
    static let youTubeWorkaround = ["--extractor-args", youTubeExtractorArgs]
    static let youTubeExtractorArgs = "youtube:player_js_variant=tv"

    struct Output {
        var stdout: Data
        /// yt-dlp succeeded but warned that the cookies are missing, invalid or expired.
        var cookiesRejected: Bool
    }

    /// Runs yt-dlp. A successful run that only warned about the cookies returns normally with
    /// `cookiesRejected` set. Throws `.authExpired` when a failed run blames the cookies,
    /// `.network`, `.processFailed` for other non-zero exits, `.toolNotFound`, `.timedOut`.
    func run(_ arguments: [String], timeout: Duration = .seconds(120)) async throws -> Output {
        let tool = try ToolLocator.url(for: "yt-dlp")
        let output = try await ProcessRunner.run(tool, arguments: Self.baseArguments + arguments, timeout: timeout)
        let failure = Self.classify(stderr: output.stderr)
        guard output.exitCode == 0 else {
            let summary = Self.summary(of: output.stderr)
            if failure == .auth { throw StowError.authExpired }
            if failure == .network { throw StowError.network(summary) }
            throw StowError.processFailed(tool: "yt-dlp", exitCode: output.exitCode, stderr: summary)
        }
        return Output(stdout: output.stdout, cookiesRejected: failure == .auth)
    }

    /// Classifies yt-dlp's stderr. Order matters: "Unable to download webpage: HTTP Error 404"
    /// is unavailable, not network.
    static func classify(stderr: String) -> Failure {
        let text = stderr.lowercased()
        let auth = ["cookies are no longer valid", "--cookies for the authentication"]
        let unavailable = ["does not exist", "http error 404", "video unavailable", "this video is private",
                           "playlist type is unviewable", "this channel does not have"]
        let network = ["unable to download", "urlopen error", "failed to resolve", "nodename nor servname",
                       "name or service not known", "temporary failure in name resolution",
                       "network is unreachable", "connection reset", "connection refused", "timed out",
                       "http error 429", "http error 5"]
        if auth.contains(where: text.contains) { return .auth }
        if unavailable.contains(where: text.contains) { return .unavailable }
        if network.contains(where: text.contains) { return .network }
        return .other
    }

    /// The ERROR lines (or the last lines) of stderr, short enough for a log entry.
    static func summary(of stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let errors = lines.filter { $0.hasPrefix("ERROR:") }
        let picked = errors.isEmpty ? Array(lines.filter { !$0.isEmpty }.suffix(3)) : errors
        return String(picked.joined(separator: "\n").prefix(500))
    }
}
