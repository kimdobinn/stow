import Foundation

/// Fetches a video's top comments with yt-dlp (about 4 s for a video's first page).
enum CommentsFetcher {
    /// yt-dlp's max_comments: in all, top-level, replies in all, replies per thread.
    static let limits = "80,40,60,6"

    static func arguments(videoId: String, cookies: URL?) -> [String] {
        // A second --extractor-args for youtube replaces the first, so this one repeats the workaround.
        var arguments = ["--no-warnings", "--skip-download", "--write-comments", "-j", "--no-playlist",
                         "--ignore-no-formats-error",
                         "--extractor-args", "\(YTDLP.youTubeExtractorArgs);max_comments=\(limits);comment_sort=top"]
        if let cookies { arguments += ["--cookies", cookies.path] }
        return arguments + ["--", "https://www.youtube.com/watch?v=\(videoId)"]
    }

    /// Signed in when `cookiesFile` is given (members-only videos need it).
    static func fetch(videoId: String, cookiesFile: URL?) async throws -> CommentsPage {
        let cookies = cookiesFile.flatMap { try? CookieCopy.make(of: $0) }
        defer { if let cookies { try? FileManager.default.removeItem(at: cookies) } }
        let output = try await YTDLP().run(arguments(videoId: videoId, cookies: cookies), timeout: .seconds(90))
        guard let page = CommentsParser.parse(json: output.stdout) else { throw StowError.parse("yt-dlp's comments") }
        return page
    }
}
