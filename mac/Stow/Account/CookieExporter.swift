import Foundation

enum CookieExporter {
    /// Cookies for these domains (and subdomains) are exported.
    static let domains = ["youtube.com", "google.com"]

    /// yt-dlp treats a session as signed in only with LOGIN_INFO plus one of these on youtube.com.
    /// YouTube clears LOGIN_INFO and SAPISID when a session dies but may keep the __Secure-3P* ones.
    static let sapisidCookieNames: Set<String> = ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"]
    static let loginInfoCookieName = "LOGIN_INFO"

    /// Expiry written for session cookies. yt-dlp drops cookies that look expired, and a
    /// session cookie stays valid as long as the web view's session, which outlives a check.
    static let sessionCookieLifetime: TimeInterval = 365 * 24 * 3600

    static func isExported(_ cookie: HTTPCookie) -> Bool {
        domains.contains { matches(cookie, domain: $0) }
    }

    /// True when youtube.com has unexpired LOGIN_INFO and SAPISID-family cookies, the same test
    /// yt-dlp uses. Google's own cookies alone are not enough: yt-dlp needs the youtube.com session.
    static func isSignedIn(_ cookies: [HTTPCookie], now: Date = .now) -> Bool {
        sessionFingerprint(cookies, now: now) != nil
    }

    /// The values of the youtube.com session cookies, or nil when signed out. Changes when the
    /// user signs in again, so a new sign-in can be told apart from a session that was already there.
    static func sessionFingerprint(_ cookies: [HTTPCookie], now: Date = .now) -> String? {
        let session = cookies
            .filter { cookie in
                (cookie.name == loginInfoCookieName || sapisidCookieNames.contains(cookie.name))
                    && matches(cookie, domain: "youtube.com")
                    && (cookie.expiresDate.map { $0 > now } ?? true)
            }
            .sorted { ($0.name, $0.domain, $0.value) < ($1.name, $1.domain, $1.value) }
        guard session.contains(where: { $0.name == loginInfoCookieName }),
              session.contains(where: { sapisidCookieNames.contains($0.name) })
        else { return nil }
        return session.map { "\($0.name)=\($0.value)" }.joined(separator: ";")
    }

    /// Netscape cookies.txt text (header line included) for the exported domains.
    static func netscapeFormat(_ cookies: [HTTPCookie], now: Date = .now) -> String {
        let sessionExpiry = Int((now.timeIntervalSince1970 + sessionCookieLifetime).rounded())
        let lines = cookies
            .filter { isExported($0) && !containsControlCharacters($0) }
            .sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
            .map { cookie in
                let expiry = cookie.expiresDate.map { Int($0.timeIntervalSince1970) } ?? sessionExpiry
                return [
                    cookie.domain,
                    cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE",
                    cookie.path,
                    cookie.isSecure ? "TRUE" : "FALSE",
                    String(expiry),
                    cookie.name,
                    cookie.value,
                ].joined(separator: "\t")
            }
        return (["# Netscape HTTP Cookie File", ""] + lines).joined(separator: "\n") + "\n"
    }

    /// Atomically writes `netscapeFormat(cookies)` to `url` with permissions 0600,
    /// creating the directory if needed. The file is never readable by others, even briefly.
    static func write(_ cookies: [HTTPCookie], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(netscapeFormat(cookies).utf8)
        let temp = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw posixError("create", temp) }
        let written = data.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        let writeError = written == data.count ? nil : posixError("write", temp)
        close(fd)
        if let writeError {
            unlink(temp.path)
            throw writeError
        }
        guard rename(temp.path, url.path) == 0 else {
            let error = posixError("replace", url)
            unlink(temp.path)
            throw error
        }
    }

    private static func matches(_ cookie: HTTPCookie, domain: String) -> Bool {
        let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }

    private static func containsControlCharacters(_ cookie: HTTPCookie) -> Bool {
        [cookie.domain, cookie.path, cookie.name, cookie.value].contains { $0.contains(where: \.isNewline) || $0.contains("\t") }
    }

    /// Reads `errno`, so call it right after the failing system call.
    private static func posixError(_ action: String, _ file: URL) -> CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not \(action) \(file.lastPathComponent): \(String(cString: strerror(errno)))"])
    }
}
