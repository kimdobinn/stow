import Foundation

/// Plain HTTP to youtube.com, the way the Mac's `YouTubeHTTP` does it: an ephemeral session that
/// never stores cookies, desktop Safari's user agent (so the pages have the shape the parsers
/// expect) and `SOCS=CAI` (no EU consent page). Only the subscriptions import sends the account's
/// cookies, and it says so.
public struct YouTubeWeb: Sendable {
    public let session: URLSession

    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    public static let acceptLanguage = "en-US,en;q=0.9"
    public static let consentCookie = "SOCS=CAI"
    static let timeout: TimeInterval = 30

    /// Tests pass a session with a stub URLProtocol.
    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }

    public struct Response: Sendable {
        public var data: Data
        public var status: Int
        /// Where the redirects ended up.
        public var url: URL?
        public var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// GET with YouTube's headers. Throws `.network` only for transport failures.
    public func get(_ url: URL, cookie: String = consentCookie) async throws -> Response {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        return try await send(request)
    }

    public func send(_ request: URLRequest) async throws -> Response {
        var request = request
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return Response(data: data, status: http?.statusCode ?? 0, url: http?.url ?? response.url)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StandaloneError.network(error.localizedDescription)
        }
    }
}
