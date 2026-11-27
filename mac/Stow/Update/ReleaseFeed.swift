import Foundation

/// A release as GitHub's REST API lists it (only the fields Stow reads).
struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable, Equatable {
        var name: String
        var browserDownloadURL: URL
        var size: Int?

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    var tagName: String
    var name: String?
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var publishedAt: Date?
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case publishedAt = "published_at"
    }

    static func decodeList(_ data: Data) throws -> [GitHubRelease] {
        do {
            return try decoder.decode([GitHubRelease].self, from: data)
        } catch {
            throw StowError.parse("GitHub releases: \(error.localizedDescription)")
        }
    }

    static func decodeOne(_ data: Data) throws -> GitHubRelease {
        do {
            return try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw StowError.parse("GitHub release: \(error.localizedDescription)")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// A Stow for Mac release: a GitHub pre-release tagged mac-v<version> with Stow-Mac-<version>.zip.
struct MacRelease: Equatable, Sendable, Codable {
    static let tagPrefix = "mac-v"

    var version: DottedVersion
    var tag: String
    /// What changed, without the checksum line.
    var notes: String
    var zipURL: URL
    var zipSize: Int?
    /// The zip's SHA-256 (lowercase hex) when the notes carry it.
    var sha256: String?
    /// A "<zip>.sha256" asset, read when the notes don't carry the checksum.
    var sha256URL: URL?
    var publishedAt: Date?

    /// The newest mac-v* release that isn't a draft and has its zip; other tags (Android v*,
    /// iPhone ios-v*) are ignored.
    static func newest(in releases: [GitHubRelease]) -> MacRelease? {
        releases.compactMap(MacRelease.init(release:)).max { $0.version < $1.version }
    }

    init?(release: GitHubRelease) {
        guard !release.draft, let version = DottedVersion(release.tagName, prefix: Self.tagPrefix) else { return nil }
        let zips = release.assets.filter { $0.name.hasSuffix(".zip") }
        guard let zip = zips.first(where: { $0.name.hasPrefix("Stow-Mac-") }) ?? zips.first else { return nil }
        self.version = version
        tag = release.tagName
        zipURL = zip.browserDownloadURL
        zipSize = zip.size
        sha256URL = release.assets.first { $0.name == zip.name + ".sha256" }?.browserDownloadURL
        let body = release.body ?? ""
        sha256 = Self.checksum(inNotes: body)
        notes = Self.notesWithoutChecksum(body)
        publishedAt = release.publishedAt
    }

    /// The hex digest on a "SHA-256: <hex>" line of the notes.
    static func checksum(inNotes notes: String) -> String? {
        for line in notes.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.lowercased().hasPrefix("sha-256:") || text.lowercased().hasPrefix("sha256:") else { continue }
            let value = text.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`")) } ?? ""
            if SHA256Sums.isDigest(value) { return value.lowercased() }
        }
        return nil
    }

    static func notesWithoutChecksum(_ notes: String) -> String {
        notes.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { checksum(inNotes: String($0)) == nil }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// yt-dlp's latest release: the standalone macOS binary and the checksums file.
struct YtDlpRelease: Equatable, Sendable {
    static let binaryName = "yt-dlp_macos"
    static let checksumsName = "SHA2-256SUMS"

    var version: DottedVersion
    var binaryURL: URL
    var checksumsURL: URL

    init?(release: GitHubRelease) {
        guard !release.draft, !release.prerelease, let version = DottedVersion(release.tagName),
              let binary = release.assets.first(where: { $0.name == Self.binaryName }),
              let sums = release.assets.first(where: { $0.name == Self.checksumsName }) else { return nil }
        self.version = version
        binaryURL = binary.browserDownloadURL
        checksumsURL = sums.browserDownloadURL
    }
}

/// Where updates come from. Debug builds (and test builds made with STOW_TEST_OVERRIDES) can point
/// them elsewhere with STOW_UPDATE_FEED_URL (a JSON list like GitHub's /releases).
enum UpdateEndpoints {
    static let macReleases = URL(string: "https://api.github.com/repos/kimdobinn/stow/releases?per_page=100")!
    static let ytDlpLatest = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    static var macReleasesFeed: URL {
        #if DEBUG || STOW_TEST_OVERRIDES
        if let text = ProcessInfo.processInfo.environment["STOW_UPDATE_FEED_URL"], let url = URL(string: text) { return url }
        #endif
        return macReleases
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Stow", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// GET `url`; throws `.network` for transport errors and non-2xx answers.
    static func fetch(_ url: URL, session: URLSession = .shared) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(url))
        } catch {
            throw StowError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let limited = http.statusCode == 403 || http.statusCode == 429
            throw StowError.network(limited ? "GitHub is limiting requests; try again later." : "HTTP \(http.statusCode) from \(url.host() ?? "the server").")
        }
        return data
    }
}
