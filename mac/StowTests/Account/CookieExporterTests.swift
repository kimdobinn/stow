import Foundation
import Testing
@testable import Stow

struct CookieExporterTests {
    static func cookie(_ name: String, _ value: String = "v", domain: String, path: String = "/", secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    // HTTPCookie caps expiry at 400 days from the real clock, so stay close to it.
    static let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
    static let later = now.addingTimeInterval(30 * 24 * 3600)

    @Test func signedInNeedsLoginInfoAndSapisidOnYouTube() {
        let loginInfo = Self.cookie("LOGIN_INFO", domain: ".youtube.com")
        #expect(!CookieExporter.isSignedIn([]))
        #expect(!CookieExporter.isSignedIn([Self.cookie("SAPISID", domain: ".youtube.com")]))
        #expect(!CookieExporter.isSignedIn([loginInfo]))
        #expect(!CookieExporter.isSignedIn([loginInfo, Self.cookie("SAPISID", domain: ".google.com")]))
        #expect(!CookieExporter.isSignedIn([loginInfo, Self.cookie("__Secure-3PSID", domain: ".youtube.com")]))
        #expect(CookieExporter.isSignedIn([loginInfo, Self.cookie("SAPISID", domain: ".youtube.com")]))
        #expect(CookieExporter.isSignedIn([Self.cookie("LOGIN_INFO", domain: "www.youtube.com"),
                                           Self.cookie("__Secure-3PAPISID", domain: ".youtube.com", expires: Self.later)], now: Self.now))
        #expect(!CookieExporter.isSignedIn([Self.cookie("LOGIN_INFO", domain: ".youtube.com", expires: Self.now),
                                            Self.cookie("SAPISID", domain: ".youtube.com")], now: Self.later))
    }

    /// What YouTube leaves behind after rejecting a dead session.
    @Test func rotatedSessionIsSignedOut() {
        #expect(!CookieExporter.isSignedIn([Self.cookie("__Secure-3PSID", domain: ".youtube.com"),
                                            Self.cookie("__Secure-3PAPISID", domain: ".youtube.com")]))
    }

    @Test func fingerprintChangesWithANewSession() {
        let old = [Self.cookie("LOGIN_INFO", "a", domain: ".youtube.com"), Self.cookie("SAPISID", "s", domain: ".youtube.com"),
                   Self.cookie("PREF", "p", domain: ".youtube.com")]
        let renewed = [Self.cookie("LOGIN_INFO", "b", domain: ".youtube.com"), Self.cookie("SAPISID", "s", domain: ".youtube.com")]
        #expect(CookieExporter.sessionFingerprint(old) == CookieExporter.sessionFingerprint(old.reversed()))
        #expect(CookieExporter.sessionFingerprint(old) != CookieExporter.sessionFingerprint(renewed))
        #expect(CookieExporter.sessionFingerprint([]) == nil)
    }

    @Test func netscapeFormat() {
        let cookies = [
            Self.cookie("SAPISID", "abc/def", domain: ".youtube.com", expires: Self.later),
            Self.cookie("NID", "n", domain: ".google.com", path: "/", secure: false, expires: Self.later),
            Self.cookie("YSC", "session", domain: ".youtube.com"),
            Self.cookie("host", "h", domain: "accounts.google.com", path: "/a"),
            Self.cookie("other", "x", domain: ".example.com"),
            Self.cookie("evil", "x", domain: ".notyoutube.com"),
        ]
        let sessionExpiry = Int(Self.now.timeIntervalSince1970 + CookieExporter.sessionCookieLifetime)
        let expiry = Int(Self.later.timeIntervalSince1970)
        let expected = """
        # Netscape HTTP Cookie File

        .google.com\tTRUE\t/\tFALSE\t\(expiry)\tNID\tn
        .youtube.com\tTRUE\t/\tTRUE\t\(expiry)\tSAPISID\tabc/def
        .youtube.com\tTRUE\t/\tTRUE\t\(sessionExpiry)\tYSC\tsession
        accounts.google.com\tFALSE\t/a\tTRUE\t\(sessionExpiry)\thost\th

        """
        #expect(CookieExporter.netscapeFormat(cookies, now: Self.now) == expected)
    }

    @Test func writeIsPrivateAndCreatesDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stow-cookies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "nested/cookies.txt")

        try CookieExporter.write([Self.cookie("SAPISID", domain: ".youtube.com")], to: file)
        try CookieExporter.write([Self.cookie("SAPISID", "rotated", domain: ".youtube.com")], to: file)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("# Netscape HTTP Cookie File\n"))
        #expect(text.contains("\tSAPISID\trotated\n"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(leftovers == ["cookies.txt"])
    }
}
