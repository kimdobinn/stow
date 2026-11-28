import CryptoKit
import Foundation

/// The signed-in account's YouTube subscriptions, for "Import from YouTube": the Mac's
/// `SubscriptionsFetcher` as plain HTTP. The first page is /feed/channels' `ytInitialData`; the
/// rest come from InnerTube's `browse` with the continuation token and the SAPISIDHASH headers
/// YouTube's own web client sends.
public struct SubscriptionsImport: Sendable {
    public let web: YouTubeWeb

    public static let feedURL = URL(string: "https://www.youtube.com/feed/channels")!
    public static let browseURL = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!
    public static let origin = "https://www.youtube.com"
    public static let maxChannels = 500
    public static let maxPages = 50

    public init(web: YouTubeWeb) {
        self.web = web
    }

    /// Every subscription, in YouTube's order. Throws `.auth` when YouTube wants a sign-in (it
    /// redirected to accounts.google.com, or the page has no data).
    public func fetch(cookies: [NetscapeCookie], now: Date = .now) async throws -> [ChannelInfo] {
        let page = try await web.get(Self.feedURL, cookie: NetscapeCookies.cookieHeader(cookies, now: now))
        if page.status == 429 { throw StandaloneError.rateLimited }
        if page.url?.host()?.hasSuffix("accounts.google.com") == true { throw StandaloneError.auth }
        guard page.status == 200, let initial = Self.initialData(page.text) else {
            if page.status >= 500 { throw StandaloneError.server(page.status) }
            throw StandaloneError.auth
        }
        let config = Self.config(page.text)
        var parsed = try SubscriptionsParser.parse(initial)
        var channels = parsed.channels
        var seen = Set(channels.map(\.id))
        var used: Set<String> = []
        var pages = 1
        while let token = parsed.continuation, used.insert(token).inserted, channels.count < Self.maxChannels, pages < Self.maxPages {
            do {
                let request = try Self.continuationRequest(token: token, config: config, cookies: cookies, now: now)
                let response = try await web.send(request)
                guard response.status == 200 else { throw StandaloneError.server(response.status) }
                parsed = try SubscriptionsParser.parse(response.data)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The pages read so far are still useful (the Mac's rule).
                break
            }
            pages += 1
            channels += parsed.channels.filter { seen.insert($0.id).inserted }
        }
        return Array(channels.prefix(Self.maxChannels))
    }

    // The page

    /// `var ytInitialData = {…};` (or `window["ytInitialData"] = {…};`).
    static func initialData(_ html: String) -> Data? {
        for marker in ["var ytInitialData = ", "window[\"ytInitialData\"] = ", "ytInitialData = "] {
            if let range = html.range(of: marker), let json = jsonObject(in: html, from: range.upperBound) {
                return Data(json.utf8)
            }
        }
        return nil
    }

    /// Every `ytcfg.set({…})` on the page, merged (INNERTUBE_CONTEXT, client name and version,
    /// SESSION_INDEX, DELEGATED_SESSION_ID).
    static func config(_ html: String) -> [String: Any] {
        var result: [String: Any] = [:]
        var searchFrom = html.startIndex
        while let range = html.range(of: "ytcfg.set({", range: searchFrom..<html.endIndex) {
            let start = html.index(before: range.upperBound)
            if let json = jsonObject(in: html, from: start),
               let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                result.merge(object) { _, new in new }
            }
            searchFrom = range.upperBound
        }
        return result
    }

    /// The balanced `{…}` starting at `start` (strings and escapes respected).
    static func jsonObject(in text: String, from start: String.Index) -> String? {
        let scalars = text.unicodeScalars
        var index = start
        while index < scalars.endIndex, scalars[index] == " " { index = scalars.index(after: index) }
        guard index < scalars.endIndex, scalars[index] == "{" else { return nil }
        let begin = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < scalars.endIndex {
            let c = scalars[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(scalars[begin...index]) }
            }
            index = scalars.index(after: index)
        }
        return nil
    }

    // Continuations

    static func continuationRequest(token: String, config: [String: Any], cookies: [NetscapeCookie], now: Date) throws -> URLRequest {
        var request = URLRequest(url: browseURL, timeoutInterval: YouTubeWeb.timeout)
        request.httpMethod = "POST"
        let body: [String: Any] = ["context": config["INNERTUBE_CONTEXT"] ?? [:], "continuation": token]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (name, value) in headers(config: config, cookies: cookies, now: now) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// The headers of the Mac's continuation script, the cookies and the user agent.
    static func headers(config: [String: Any], cookies: [NetscapeCookie], now: Date) -> [String: String] {
        func string(_ key: String, _ fallback: String) -> String {
            switch config[key] {
            case let value as String: value
            case let value as NSNumber: value.stringValue
            default: fallback
            }
        }
        var headers = [
            "Content-Type": "application/json",
            "X-Origin": origin,
            "Origin": origin,
            "X-Goog-AuthUser": string("SESSION_INDEX", "0"),
            "X-Youtube-Client-Name": string("INNERTUBE_CONTEXT_CLIENT_NAME", "1"),
            "X-Youtube-Client-Version": string("INNERTUBE_CLIENT_VERSION", ""),
            "User-Agent": YouTubeWeb.userAgent,
            "Accept-Language": YouTubeWeb.acceptLanguage,
            "Cookie": NetscapeCookies.cookieHeader(cookies, now: now),
        ]
        if let authorization = authorization(cookies: cookies, now: now) { headers["Authorization"] = authorization }
        if let pageId = config["DELEGATED_SESSION_ID"] as? String, !pageId.isEmpty { headers["X-Goog-PageId"] = pageId }
        return headers
    }

    /// `SAPISIDHASH <ts>_<sha1("<ts> <sid> https://www.youtube.com")>` and its 1P and 3P siblings.
    static func authorization(cookies: [NetscapeCookie], now: Date) -> String? {
        func value(_ name: String) -> String? {
            cookies.filter { $0.name == name && $0.matches("youtube.com") }.max { $0.domain.count < $1.domain.count }?.value
        }
        let timestamp = Int(now.timeIntervalSince1970)
        let schemes: [(String, String?)] = [
            ("SAPISIDHASH", value("SAPISID") ?? value("__Secure-3PAPISID")),
            ("SAPISID1PHASH", value("__Secure-1PAPISID")),
            ("SAPISID3PHASH", value("__Secure-3PAPISID")),
        ]
        let parts = schemes.compactMap { scheme, sid in sid.map { "\(scheme) \(sapisidHash(sid: $0, timestamp: timestamp))" } }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// `<ts>_<sha1 hex of "<ts> <sid> <origin>">`.
    public static func sapisidHash(sid: String, timestamp: Int, origin: String = origin) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sid) \(origin)".utf8))
        return "\(timestamp)_" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The import picker's selection: nothing is picked at first (the app never imports everything
/// by itself), followed channels show as added and can't be unpicked.
public struct ImportSelection: Equatable, Sendable {
    public let channels: [ChannelInfo]
    public let followed: Set<String>
    public private(set) var picked: Set<String> = []

    public init(channels: [ChannelInfo], followed: Set<String>) {
        self.channels = channels
        self.followed = followed
    }

    public func isAdded(_ id: String) -> Bool { followed.contains(id) }
    public func isPicked(_ id: String) -> Bool { picked.contains(id) || followed.contains(id) }

    public mutating func toggle(_ id: String) {
        guard !followed.contains(id) else { return }
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    /// "Select all": an explicit tap, never done for the user.
    public mutating func selectAll(matching ids: [String]? = nil) {
        picked.formUnion((ids ?? channels.map(\.id)).filter { !followed.contains($0) })
    }

    public mutating func selectNone() { picked = [] }

    /// The picked channels in YouTube's order.
    public var toAdd: [ChannelInfo] { channels.filter { picked.contains($0.id) } }

    public static func == (a: ImportSelection, b: ImportSelection) -> Bool {
        a.channels == b.channels && a.followed == b.followed && a.picked == b.picked
    }
}
