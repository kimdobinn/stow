import WebKit

/// The persistent WebKit data store dedicated to Stow's YouTube login, isolated from Safari.
@MainActor
enum WebDataStore {
    static let identifier = UUID(uuidString: "1A08EC79-2B42-4DAC-B302-C8F98E1ADC2C")!

    static let shared = WKWebsiteDataStore(forIdentifier: identifier)

    /// Google refuses sign-in from browsers it identifies as embedded web views, and WKWebView's
    /// default user agent lacks the "Version/… Safari/…" suffix. Present as desktop Safari.
    /// Risk: Google may still block this some day; bump the version when Safari updates.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"

    /// A configuration whose web views share the dedicated store.
    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = shared
        return configuration
    }

    /// Cookies in the store for `CookieExporter.domains`.
    static func cookies() async -> [HTTPCookie] {
        await shared.httpCookieStore.allCookies().filter(CookieExporter.isExported)
    }

    /// Removes every cookie, cache and storage record from the store.
    static func removeAll() async {
        await shared.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
