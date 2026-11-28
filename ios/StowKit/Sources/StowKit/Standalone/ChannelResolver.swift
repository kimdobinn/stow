import Foundation

/// What the user typed, classified without the network.
public enum ChannelReference: Equatable, Sendable {
    /// "UC…" channel id.
    case id(String)
    /// Handle without the leading "@".
    case handle(String)
    /// A legacy /c/ or /user/ channel URL, on www.youtube.com.
    case url(URL)
    /// A video id: resolves to the uploader's channel.
    case video(String)
}

/// Turns a channel URL, @handle, channel ID or video URL into a channel: a port of the Mac's
/// `ChannelResolver`. The channel page answers first; yt-dlp when the page can't be read.
public struct ChannelResolver: Sendable {
    public let web: YouTubeWeb
    public let youtube: YouTubeTool

    public init(web: YouTubeWeb, youtube: YouTubeTool) {
        self.web = web
        self.youtube = youtube
    }

    /// Nil when the input can't be a channel reference.
    public static func parse(input: String) -> ChannelReference? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isChannelId(text) { return .id(text) }
        if text.hasPrefix("@") { return handle(String(text.dropFirst())).map(ChannelReference.handle) }
        let lowered = text.lowercased()
        if lowered.contains("youtube.com") || lowered.contains("youtu.be") { return parseURL(text) }
        return handle(text).map(ChannelReference.handle)
    }

    public func resolve(input: String) async throws -> ChannelInfo {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reference = Self.parse(input: input) else { throw StandaloneError.invalidInput(input) }
        switch reference {
        case .id(let id): return try await resolvePage(Self.channelURL(id: id), input: input)
        case .handle(let handle): return try await resolvePage(Self.handleURL(handle), input: input)
        case .url(let url): return try await resolvePage(url, input: input)
        case .video(let videoId):
            let channelId = try await owningChannelId(videoId: videoId, input: input)
            return try await resolvePage(Self.channelURL(id: channelId), input: input)
        }
    }

    // Network

    private func resolvePage(_ url: URL, input: String) async throws -> ChannelInfo {
        let response = try await web.get(url)
        if response.status == 404 { throw StandaloneError.notFound(input) }
        if response.status == 429 { throw StandaloneError.rateLimited }
        if response.status == 200, let info = ChannelPageParser.parse(html: response.text) { return info }
        return try await resolveWithYtDlp(url, input: input)
    }

    private func resolveWithYtDlp(_ url: URL, input: String) async throws -> ChannelInfo {
        let listing = try await mapNotFound(input) { try await youtube.flatListing(url.absoluteString, count: 0, cookies: nil) }
        guard let root = try? JSONObject(parsing: listing.json), let id = root.string("channel_id"), Self.isChannelId(id) else {
            throw StandaloneError.notFound(input)
        }
        let uploader = root.string("uploader_id")
        return ChannelInfo(id: id, title: root.string("channel") ?? id,
                           handle: uploader?.hasPrefix("@") == true ? uploader : nil,
                           avatarURL: YouTubeListing.channelAvatar(listing.json))
    }

    private func owningChannelId(videoId: String, input: String) async throws -> String {
        let watch = URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
        let response = try await web.get(watch)
        if response.status == 429 { throw StandaloneError.rateLimited }
        if response.status == 200, let id = ChannelPageParser.ownerChannelId(watchPage: response.text) { return id }
        let json = try await mapNotFound(input) { try await youtube.info(videoId: videoId, cookies: nil) }
        guard let root = try? JSONObject(parsing: json), let id = root.string("channel_id"), Self.isChannelId(id) else {
            throw StandaloneError.notFound(input)
        }
        return id
    }

    private func mapNotFound<T>(_ input: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if YouTubeFailure.classify(error) == .unavailable { throw StandaloneError.notFound(input) }
            throw error
        }
    }

    // Parsing

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

    public static func isChannelId(_ text: String) -> Bool {
        text.wholeMatch(of: #/UC[\w-]{22}/#) != nil
    }

    static func channelURL(id: String) -> URL {
        URL(string: "https://www.youtube.com/channel/\(id)")!
    }

    static func handleURL(_ handle: String) -> URL {
        URL(string: "https://www.youtube.com")!.appending(path: "@" + handle)
    }
}
