import Foundation
@testable import StowKit

/// A fake Google: answers URLSession requests in-process, never over the network. Each stub
/// has its own session (routed by a header), so tests can run in parallel.
final class StubServer: @unchecked Sendable {
    struct Request {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data

        var path: String { url.path }
        var query: [String: [String]] {
            var result: [String: [String]] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                result[item.name, default: []].append(item.value ?? "")
            }
            return result
        }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var bodyText: String { String(decoding: body, as: UTF8.self) }
    }

    typealias Handler = (Request) -> (status: Int, body: String)

    let id = UUID().uuidString
    private let lock = NSLock()
    private var handler: Handler
    private var _requests: [Request] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
        StubURLProtocol.register(self)
    }

    var requests: [Request] { lock.withLock { _requests } }

    func setHandler(_ handler: @escaping Handler) { lock.withLock { self.handler = handler } }

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.header: id]
        return URLSession(configuration: configuration)
    }()

    func respond(to request: Request) -> (Int, String) {
        lock.withLock {
            _requests.append(request)
            return handler(request)
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-Stub-Server"
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: StubServer) { lock.withLock { servers[server.id] = server } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        guard let server = Self.lock.withLock({ Self.servers[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let (status, text) = server.respond(to: .init(method: request.httpMethod ?? "GET", url: url,
                                                      headers: request.allHTTPHeaderFields ?? [:], body: body))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A made-up project: tests never talk to a real one.
let testConfig = FirebaseConfig(projectId: "stow-test", apiKey: "test-api-key")
let documentsPrefix = "/v1/projects/stow-test/databases/(default)/documents"

func fixture(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw StowError.parse("No fixture \(name)")
    }
    return try String(contentsOf: url, encoding: .utf8)
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "StowKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func freshDefaults() -> UserDefaults {
    let name = "StowKitTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

func validTokens(uid: String = "phone-uid") -> AuthTokens {
    AuthTokens(uid: uid, idToken: "id-token-1", refreshToken: "refresh-1", expiresAt: .now.addingTimeInterval(3600))
}

/// Waits (briefly) until `condition` holds, for work the code under test starts in the background.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A YouTube that answers from memory.
final class FakeYouTube: YouTubeTool, @unchecked Sendable {
    private let lock = NSLock()
    var searchJSON = #"{"entries":[]}"#
    var channelJSON: [String: String] = [:]
    var commentsJSON = #"{"comments":[],"comment_count":0}"#
    /// Fails this many downloads before one works.
    var failures = 0
    var failureMessage = "ERROR: HTTP Error 403: Forbidden"
    /// While true, downloads wait (until canceled or released).
    var holdDownloads = false
    private(set) var downloadCalls: [String] = []
    private(set) var cancelCalls: [String] = []
    private(set) var cookiesSeen: [URL?] = []

    func info(videoId: String, cookies: URL?) async throws -> String { #"{"id":"\#(videoId)"}"# }

    func search(_ query: String, count: Int) async throws -> String { lock.withLock { searchJSON } }

    func channelTab(channelId: String, tab: ChannelTab, count: Int) async throws -> String {
        guard let json = lock.withLock({ channelJSON["\(channelId)/\(tab.rawValue)"] }) else {
            throw StowError.server("ERROR: This channel does not have a \(tab.rawValue) tab")
        }
        return json
    }

    func comments(videoId: String, cookies: URL?) async throws -> String { lock.withLock { commentsJSON } }

    func stream(_ video: Video, cookies: URL?) async throws -> StreamInfo {
        StreamInfo(url: URL(string: "https://example.invalid/\(video.id).m3u8")!)
    }

    func downloadSize(_ video: Video, cookies: URL?, quality: DownloadQuality) async throws -> Int64? { 1234 }

    func download(_ video: Video, cookies: URL?, quality: DownloadQuality, to directory: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let shouldFail: Bool = lock.withLock {
            downloadCalls.append(video.id)
            cookiesSeen.append(cookies)
            if failures > 0 { failures -= 1; return true }
            return false
        }
        progress(0.5)
        while lock.withLock({ holdDownloads }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        if shouldFail { throw StowError.server(lock.withLock { failureMessage }) }
        let file = directory.appending(path: "\(video.id).mp4")
        try Data("fake video \(video.id)".utf8).write(to: file)
        progress(1)
        return file
    }

    func cancel(videoId: String) { lock.withLock { cancelCalls.append(videoId) } }

    func release() { lock.withLock { holdDownloads = false } }
}
