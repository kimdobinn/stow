import Foundation

/// Reads and writes the signed-in account's YouTube watch history through yt-dlp. YouTube's
/// API has no watch history, so this uses the same cookies as the members-only feeds.
struct WatchHistoryClient: Sendable {
    let ytdlp: YTDLP

    /// yt-dlp --flat-playlist -J --playlist-end <limit> :ythistory
    func fetch(cookiesFile: URL, limit: Int) async throws -> WatchHistory {
        let cookies = try CookieCopy.make(of: cookiesFile)
        defer { try? FileManager.default.removeItem(at: cookies) }
        let output = try await ytdlp.run(["--cookies", cookies.path, "--flat-playlist", "-J",
                                          "--playlist-end", String(limit), ":ythistory"])
        return WatchHistory(videoIds: try Self.parse(historyJSON: output.stdout), cookiesRejected: output.cookiesRejected)
    }

    /// yt-dlp --simulate --mark-watched <video>: YouTube records a view, as if it was played there.
    func markWatched(videoId: String, cookiesFile: URL) async throws {
        let cookies = try CookieCopy.make(of: cookiesFile)
        defer { try? FileManager.default.removeItem(at: cookies) }
        let output = try await ytdlp.run(["--cookies", cookies.path, "--simulate", "--mark-watched", "--quiet",
                                          "https://www.youtube.com/watch?v=\(videoId)"],
                                         timeout: .seconds(60))
        if output.cookiesRejected { throw StowError.authExpired }
    }

    /// The history playlist's video ids, most recently watched first, without repeats (a video
    /// watched twice in a day is listed twice).
    static func parse(historyJSON: Data) throws -> [String] {
        let history: History?
        do {
            history = try JSONDecoder().decode(History?.self, from: historyJSON)
        } catch {
            throw StowError.parse("yt-dlp history JSON: \(error.localizedDescription)")
        }
        var seen = Set<String>()
        return (history?.entries ?? []).compactMap { $0?.id }.filter { seen.insert($0).inserted }
    }
}

private struct History: Decodable {
    var entries: [Entry?]?

    struct Entry: Decodable {
        var id: String
    }
}
