import Foundation

/// The phone's own YouTube sign-in, in standalone mode. Optional: public channels and videos
/// work without it.
public enum AccountState: String, Codable, Sendable {
    case signedOut, signedIn
    /// YouTube stopped accepting the sign-in (sticky until a probe works, or a new sign-in or sign-out).
    case expired
}

/// Where the sign-in came from.
public enum AccountSource: String, Codable, Sendable {
    /// The in-app web login.
    case web
    /// A cookies.txt the user picked.
    case file
}

/// standalone.json's `account`: whether there is a sign-in, never the cookies themselves.
public struct StandaloneAccount: Codable, Hashable, Sendable {
    public var state: AccountState
    public var since: Date?
    public var source: AccountSource?
    /// The last recovery probe while expired (at most hourly).
    public var lastProbeAt: Date?

    public init(state: AccountState = .signedOut, since: Date? = nil, source: AccountSource? = nil, lastProbeAt: Date? = nil) {
        self.state = state
        self.since = since
        self.source = source
        self.lastProbeAt = lastProbeAt
    }

    public static let signedOut = StandaloneAccount()

    /// Signed in, expired or not: there are cookies.
    public var hasCookies: Bool { state != .signedOut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? c.decodeIfPresent(AccountState.self, forKey: .state)) ?? .signedOut
        since = try? c.decodeIfPresent(Date.self, forKey: .since)
        source = try? c.decodeIfPresent(AccountSource.self, forKey: .source)
        lastProbeAt = try? c.decodeIfPresent(Date.self, forKey: .lastProbeAt)
    }
}

/// The sign-in's cookies, kept in a `CookieVault`, and what can be told from them.
public struct YouTubeAccount: Sendable {
    public let vault: CookieVault

    public init(vault: CookieVault) {
        self.vault = vault
    }

    public var cookiesText: String? { vault.load().map { String(decoding: $0, as: UTF8.self) } }

    public var cookies: [NetscapeCookie] { cookiesText.map(NetscapeCookies.parse) ?? [] }

    /// A cookies.txt's youtube.com and google.com cookies, written out again; throws `.noSignIn`
    /// when it has no YouTube session. The user's file itself is never changed.
    public static func validated(_ text: String, now: Date = .now) throws -> String {
        let cookies = NetscapeCookies.parse(text)
        guard NetscapeCookies.isSignedIn(cookies, now: now) else { throw StandaloneError.noSignIn }
        return NetscapeCookies.format(cookies, now: now)
    }

    /// Throws when the vault couldn't keep it.
    public func store(_ text: String) throws { try vault.save(Data(text.utf8)) }

    public func delete() throws { try vault.save(nil) }

    /// LOGIN_INFO's stored expiry has passed (known for files and the iPhone's web login).
    public func loginInfoExpired(now: Date = .now) -> Bool {
        guard let expiry = NetscapeCookies.loginInfoExpiry(cookies) else { return false }
        return expiry <= now
    }

    /// The cookies as a temporary cookies.txt (mode 0600) for one yt-dlp call; the caller deletes it.
    public func temporaryFile(directory: URL = FileManager.default.temporaryDirectory) -> URL? {
        guard let data = vault.load() else { return nil }
        let url = directory.appending(path: "cookies-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        return url
    }
}
