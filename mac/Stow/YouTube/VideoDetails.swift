import Foundation

/// Duration, live status and playability of videos from `yt-dlp -J` (mpv's own lookup). A run that
/// succeeds resolved the streams, so mpv (which uses the same yt-dlp) should be able to play it.
struct YTDLPVideoDetails: VideoDetailsService {
    static let maxConcurrent = 3
    static let timeout: Duration = .seconds(60)

    func details(for ids: [String], cookiesFile: URL?) async -> [String: VideoDetails] {
        var seen = Set<String>()
        var pending = ids.filter { seen.insert($0).inserted }.makeIterator()
        return await withTaskGroup(of: VideoDetails.self) { group in
            for _ in 0..<Self.maxConcurrent {
                guard let id = pending.next() else { break }
                group.addTask { await Self.lookUp(id, cookiesFile: cookiesFile) }
            }
            var results: [String: VideoDetails] = [:]
            for await details in group {
                results[details.id] = details
                if let id = pending.next() { group.addTask { await Self.lookUp(id, cookiesFile: cookiesFile) } }
            }
            return results
        }
    }

    private static func lookUp(_ id: String, cookiesFile: URL?) async -> VideoDetails {
        // Signed out (or the file vanished): members-only videos then come back not playable.
        let cookies = cookiesFile.flatMap { try? CookieCopy.make(of: $0) }
        defer { if let cookies { try? FileManager.default.removeItem(at: cookies) } }
        // mpv's own lookup, so the answer is kept for the player (the alarm then starts each
        // video without looking it up again).
        let arguments = StreamCache.arguments(videoId: id, format: MPVPlayer.format, cookies: cookies)
        do {
            let output = try await YTDLP().run(arguments, timeout: timeout)
            let details = try parse(json: output.stdout, id: id)
            StreamCache.store(json: output.stdout, videoId: id)
            return details
        } catch {
            return VideoDetails(id: id, duration: nil, liveStatus: .unknown, isPlayable: false, error: error.logDescription)
        }
    }

    /// Parses yt-dlp's video JSON. Throws `.parse` when it isn't a video object.
    static func parse(json: Data, id: String) throws -> VideoDetails {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let info = try? decoder.decode(Info?.self, from: json) else {
            throw StowError.parse("yt-dlp video JSON for \(id)")
        }
        let status = liveStatus(info.liveStatus, isLive: info.isLive)
        let upcoming = status == .upcoming
        return VideoDetails(id: info.id ?? id, duration: info.duration, liveStatus: status, isPlayable: !upcoming,
                            error: upcoming ? "The premiere or stream hasn't started." : nil)
    }

    private static func liveStatus(_ value: String?, isLive: Bool?) -> LiveStatus {
        switch value {
        case "not_live": .none
        case "is_live": .live
        case "is_upcoming": .upcoming
        case "was_live", "post_live": .wasLive
        default: isLive == true ? .live : .unknown
        }
    }

    private struct Info: Decodable {
        var id: String?
        var duration: Double?
        var liveStatus: String?
        var isLive: Bool?
    }
}
