import Foundation

/// What the user typed, classified without network access.
enum ChannelReference: Equatable, Sendable {
    /// "UC…" channel id.
    case id(String)
    /// Handle without the leading "@".
    case handle(String)
    /// A legacy /c/ or /user/ channel URL, normalized to www.youtube.com.
    case url(URL)
    /// A video id; resolves to the uploader's channel.
    case video(String)
}

struct ChannelResolver: Sendable {
    var ytdlp = YTDLP()

    /// Nil when the input can't be a channel reference.
    static func parse(input: String) -> ChannelReference? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isChannelId(text) { return .id(text) }
        if text.hasPrefix("@") { return handle(String(text.dropFirst())).map(ChannelReference.handle) }
        let lowered = text.lowercased()
        if lowered.contains("youtube.com") || lowered.contains("youtu.be") { return parseURL(text) }
        return handle(text).map(ChannelReference.handle)
    }

    func resolve(input: String) async throws -> ChannelInfo {
        guard let reference = Self.parse(input: input) else { throw StowError.invalidChannelInput(input) }
        switch reference {
        case .id(let id): return try await resolvePage(Self.channelURL(id: id), input: input)
        case .handle(let handle): return try await resolvePage(Self.handleURL(handle), input: input)
        case .url(let url): return try await resolvePage(url, input: input)
        case .video(let videoId):
            let channelId = try await owningChannelId(videoId: videoId, input: input)
            return try await resolvePage(Self.channelURL(id: channelId), input: input)
        }
    }

    // MARK: - Network

    /// Scrapes the channel page; falls back to yt-dlp when the page can't be parsed.
    private func resolvePage(_ url: URL, input: String) async throws -> ChannelInfo {
        let (data, status) = try await YouTubeHTTP.get(url)
        if status == 404 { throw StowError.channelNotFound(input) }
        if status == 200, let info = ChannelPageParser.parse(html: String(decoding: data, as: UTF8.self)) {
            return info
        }
        return try await resolveWithYTDLP(url, input: input)
    }

    private func resolveWithYTDLP(_ url: URL, input: String) async throws -> ChannelInfo {
        let json = try await mapNotFound(input) {
            try await ytdlp.run(["-J", "--flat-playlist", "--playlist-items", "0", url.absoluteString], timeout: .seconds(60)).stdout
        }
        guard let channel = try? JSONDecoder().decode(YTDLPChannel.self, from: json), Self.isChannelId(channel.channel_id) else {
            throw StowError.channelNotFound(input)
        }
        let avatar = channel.thumbnails?.first { $0.id == "avatar_uncropped" }?.url
        return ChannelInfo(id: channel.channel_id, title: channel.channel ?? channel.channel_id,
                           handle: channel.uploader_id?.hasPrefix("@") == true ? channel.uploader_id : nil,
                           avatarURL: avatar.flatMap(URL.init(string:)))
    }

    private func owningChannelId(videoId: String, input: String) async throws -> String {
        let watch = URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
        let (data, status) = try await YouTubeHTTP.get(watch)
        if status == 200, let id = ChannelPageParser.ownerChannelId(watchPage: String(decoding: data, as: UTF8.self)) {
            return id
        }
        let json = try await mapNotFound(input) {
            try await ytdlp.run(["-J", "--skip-download", watch.absoluteString], timeout: .seconds(60)).stdout
        }
        guard let video = try? JSONDecoder().decode(YTDLPChannel.self, from: json), Self.isChannelId(video.channel_id) else {
            throw StowError.channelNotFound(input)
        }
        return video.channel_id
    }

    private func mapNotFound(_ input: String, _ body: () async throws -> Data) async throws -> Data {
        do {
            return try await body()
        } catch StowError.processFailed(_, _, let stderr) where YTDLP.classify(stderr: stderr) == .unavailable {
            throw StowError.channelNotFound(input)
        }
    }

    // MARK: - Parsing helpers

    private static func parseURL(_ text: String) -> ChannelReference? {
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: withScheme), let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }

        if host == "youtu.be" { return parts.first.flatMap(videoId).map(ChannelReference.video) }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com"), let first = parts.first else { return nil }

        if first.hasPrefix("@") { return handle(String(first.dropFirst())).map(ChannelReference.handle) }
        let second = parts.count > 1 ? parts[1] : nil
        switch first {
        case "channel":
            return second.flatMap { isChannelId($0) ? .id($0) : nil }
        case "c", "user":
            return second.map { .url(URL(string: "https://www.youtube.com")!.appending(path: first).appending(path: $0)) }
        case "watch":
            let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            return v.flatMap(videoId).map(ChannelReference.video)
        case "shorts", "live", "embed", "v":
            return second.flatMap(videoId).map(ChannelReference.video)
        default:
            return nil
        }
    }

    /// Handles allow letters in any script, digits, ".", "_", "-" and "·".
    private static func handle(_ text: String) -> String? {
        guard (1...100).contains(text.count),
              text.allSatisfy({ $0.isLetter || $0.isNumber || "._-·".contains($0) }) else { return nil }
        return text
    }

    private static func videoId(_ text: String) -> String? {
        text.wholeMatch(of: #/[\w-]{11}/#) != nil ? text : nil
    }

    static func isChannelId(_ text: String) -> Bool {
        text.wholeMatch(of: #/UC[\w-]{22}/#) != nil
    }

    private static func channelURL(id: String) -> URL {
        URL(string: "https://www.youtube.com/channel/\(id)")!
    }

    private static func handleURL(_ handle: String) -> URL {
        URL(string: "https://www.youtube.com")!.appending(path: "@" + handle)
    }
}

/// The subset of yt-dlp -J output used for channel and video lookups.
private struct YTDLPChannel: Decodable {
    struct Thumbnail: Decodable {
        var id: String?
        var url: String?
    }

    var channel_id: String
    var channel: String?
    var uploader_id: String?
    var thumbnails: [Thumbnail]?
}
