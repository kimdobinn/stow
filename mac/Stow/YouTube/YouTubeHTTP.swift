import Foundation

/// Cookie-less GETs against youtube.com. Uses its own ephemeral session so nothing leaks
/// into (or out of) the signed-in web data store.
enum YouTubeHTTP {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Returns the body and status code; throws `.network` only for transport failures.
    static func get(_ url: URL) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        // A desktop browser UA gets the full page with og: tags; SOCS skips the EU consent page.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw StowError.network(error.localizedDescription)
        }
    }
}
