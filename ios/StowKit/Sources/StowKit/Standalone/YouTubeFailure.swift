import Foundation

/// What a yt-dlp failure (or warning) is about, from its text: a port of the Mac's `YTDLP.classify`.
/// The classes are checked in this order: "Unable to download webpage: HTTP Error 404" is
/// unavailable, not network.
public enum YouTubeFailure: String, Sendable, Equatable {
    /// The cookies are missing, invalid or rotated: YouTube wants a sign-in.
    case auth
    /// The video, playlist or tab doesn't exist or can't be viewed.
    case unavailable
    case network
    case other

    public static func classify(_ text: String) -> YouTubeFailure {
        let text = text.lowercased()
        if authMarks.contains(where: text.contains) { return .auth }
        if unavailableMarks.contains(where: text.contains) { return .unavailable }
        if networkMarks.contains(where: text.contains) { return .network }
        return .other
    }

    public static func classify(_ error: Error) -> YouTubeFailure {
        if let error = error as? StandaloneError {
            switch error {
            case .auth: return .auth
            case .notFound: return .unavailable
            case .network, .rateLimited, .server: return .network
            case .invalidInput, .alreadyAdded, .noSignIn, .rejected, .other: return .other
            }
        }
        return classify(message(error))
    }

    /// YouTube asked to slow down (HTTP 429), in yt-dlp's words.
    public static func isRateLimited(_ text: String) -> Bool {
        text.lowercased().contains("http error 429")
    }

    /// A successful run's warnings say the cookies weren't accepted.
    public static func cookiesRejected(warnings: String) -> Bool {
        classify(warnings) == .auth
    }

    static let authMarks = ["cookies are no longer valid", "--cookies for the authentication"]
    static let unavailableMarks = ["does not exist", "http error 404", "video unavailable", "this video is private",
                                   "playlist type is unviewable", "this channel does not have"]
    static let networkMarks = ["unable to download", "urlopen error", "failed to resolve", "nodename nor servname",
                               "name or service not known", "temporary failure in name resolution",
                               "network is unreachable", "connection reset", "connection refused", "timed out",
                               "http error 429", "http error 5"]

    /// One line, at most 300 characters, for logs and the status footer.
    static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
}

/// Errors of the standalone mode. `message` is short enough to show as it is.
public enum StandaloneError: Error, Equatable, Sendable, LocalizedError {
    /// Not a channel URL, @handle or channel ID.
    case invalidInput(String)
    case notFound(String)
    /// "<title> is already added."
    case alreadyAdded(String)
    /// YouTube wants a sign-in (or rejected the one it got).
    case auth
    /// A cookies.txt without YouTube's session cookies.
    case noSignIn
    /// The verification call said the cookies aren't accepted.
    case rejected
    /// HTTP 429, or yt-dlp's "HTTP Error 429".
    case rateLimited
    case server(Int)
    case network(String)
    case other(String)

    public var message: String {
        switch self {
        case .invalidInput(let input): "Not a channel URL, @handle or channel ID: \(input)"
        case .notFound(let input): "Channel not found: \(input)"
        case .alreadyAdded(let title): "\(title) is already added."
        case .auth: "YouTube signed you out. Sign in again."
        case .noSignIn: "This file has no YouTube sign-in."
        case .rejected: "YouTube didn't accept this sign-in."
        case .rateLimited: "YouTube asked Stow to slow down. It'll try again later."
        case .server(let status): "YouTube answered HTTP \(status)."
        case .network(let message), .other(let message): message
        }
    }

    public var errorDescription: String? { message }
}
