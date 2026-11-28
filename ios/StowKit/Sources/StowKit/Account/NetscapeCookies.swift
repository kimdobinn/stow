import Foundation

/// One cookie as a Netscape cookies.txt line holds it.
public struct NetscapeCookie: Hashable, Sendable {
    public var domain: String
    /// The second column: the cookie is sent to subdomains too (domain starts with ".").
    public var includeSubdomains: Bool
    public var path: String
    public var secure: Bool
    /// nil: a session cookie (0 in the file).
    public var expires: Date?
    public var name: String
    public var value: String

    public init(domain: String, includeSubdomains: Bool? = nil, path: String = "/", secure: Bool = true,
                expires: Date?, name: String, value: String) {
        self.domain = domain
        self.includeSubdomains = includeSubdomains ?? domain.hasPrefix(".")
        self.path = path
        self.secure = secure
        self.expires = expires
        self.name = name
        self.value = value
    }

    public init(_ cookie: HTTPCookie) {
        self.init(domain: cookie.domain, path: cookie.path, secure: cookie.isSecure, expires: cookie.expiresDate,
                  name: cookie.name, value: cookie.value)
    }

    var host: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }

    func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
}

/// Netscape cookies.txt, as yt-dlp reads it: the Mac's `CookieExporter` ported, plus a parser
/// for files people bring.
public enum NetscapeCookies {
    /// Cookies for these domains (and subdomains) are kept; everything else is dropped.
    public static let domains = ["youtube.com", "google.com"]
    /// yt-dlp treats a session as signed in only with LOGIN_INFO plus one of these on youtube.com.
    public static let sapisidCookieNames: Set<String> = ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"]
    public static let loginInfoCookieName = "LOGIN_INFO"
    /// Expiry written for session cookies: yt-dlp drops cookies that look expired.
    public static let sessionCookieLifetime: TimeInterval = 365 * 24 * 3600
    public static let header = "# Netscape HTTP Cookie File"

    public static func isKept(_ cookie: NetscapeCookie) -> Bool {
        domains.contains { cookie.matches($0) }
    }

    /// cookies.txt text (header line included) for the kept domains, sorted by domain, path and name.
    public static func format(_ cookies: [NetscapeCookie], now: Date = .now) -> String {
        let sessionExpiry = Int((now.timeIntervalSince1970 + sessionCookieLifetime).rounded())
        let lines = cookies
            .filter { isKept($0) && !containsControlCharacters($0) }
            .sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
            .map { cookie in
                let expiry = cookie.expires.map { Int($0.timeIntervalSince1970) } ?? sessionExpiry
                return [cookie.domain, cookie.includeSubdomains ? "TRUE" : "FALSE", cookie.path,
                        cookie.secure ? "TRUE" : "FALSE", String(expiry), cookie.name, cookie.value].joined(separator: "\t")
            }
        return ([header, ""] + lines).joined(separator: "\n") + "\n"
    }

    public static func format(httpCookies cookies: [HTTPCookie], now: Date = .now) -> String {
        format(cookies.map(NetscapeCookie.init), now: now)
    }

    /// The youtube.com and google.com cookies of a cookies.txt. Accepts `#HttpOnly_` lines, skips
    /// comments, blank lines and lines without 7 tab-separated fields.
    public static func parse(_ text: String) -> [NetscapeCookie] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> NetscapeCookie? in
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("#HttpOnly_") {
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                return nil
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, !fields[0].isEmpty, !fields[5].isEmpty else { return nil }
            let seconds = Double(fields[4]) ?? 0
            let cookie = NetscapeCookie(domain: fields[0], includeSubdomains: fields[1].uppercased() == "TRUE",
                                        path: fields[2].isEmpty ? "/" : fields[2], secure: fields[3].uppercased() == "TRUE",
                                        expires: seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil,
                                        name: fields[5], value: fields[6])
            return isKept(cookie) ? cookie : nil
        }
    }

    /// The values of the youtube.com session cookies, or nil when signed out: unexpired
    /// LOGIN_INFO plus a SAPISID-family cookie, the test yt-dlp uses.
    public static func sessionFingerprint(_ cookies: [NetscapeCookie], now: Date = .now) -> String? {
        let session = cookies
            .filter { cookie in
                (cookie.name == loginInfoCookieName || sapisidCookieNames.contains(cookie.name))
                    && cookie.matches("youtube.com")
                    && (cookie.expires.map { $0 > now } ?? true)
            }
            .sorted { ($0.name, $0.domain, $0.value) < ($1.name, $1.domain, $1.value) }
        guard session.contains(where: { $0.name == loginInfoCookieName }),
              session.contains(where: { sapisidCookieNames.contains($0.name) })
        else { return nil }
        return session.map { "\($0.name)=\($0.value)" }.joined(separator: ";")
    }

    public static func isSignedIn(_ cookies: [NetscapeCookie], now: Date = .now) -> Bool {
        sessionFingerprint(cookies, now: now) != nil
    }

    /// When youtube.com's LOGIN_INFO runs out (nil for a session cookie or none at all).
    public static func loginInfoExpiry(_ cookies: [NetscapeCookie]) -> Date? {
        cookies.filter { $0.name == loginInfoCookieName && $0.matches("youtube.com") }.compactMap(\.expires).max()
    }

    /// youtube.com's cookies as a `Cookie:` header (`name=value; …`), for the subscriptions page.
    public static func cookieHeader(_ cookies: [NetscapeCookie], now: Date = .now) -> String {
        var seen = Set<String>()
        var pairs = cookies
            .filter { $0.matches("youtube.com") && ($0.expires.map { $0 > now } ?? true) }
            .sorted { ($0.domain.count, $0.name) > ($1.domain.count, $1.name) }
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
        if !seen.contains("SOCS") { pairs.append(YouTubeWeb.consentCookie) }
        return pairs.joined(separator: "; ")
    }

    private static func containsControlCharacters(_ cookie: NetscapeCookie) -> Bool {
        [cookie.domain, cookie.path, cookie.name, cookie.value].contains { $0.contains(where: \.isNewline) || $0.contains("\t") }
    }
}
