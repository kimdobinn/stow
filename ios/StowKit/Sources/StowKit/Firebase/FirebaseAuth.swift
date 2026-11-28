import Foundation
import Security

/// The Firebase project the app is built for (ios/Stow/Config/Firebase.plist: ProjectID, APIKey).
public struct FirebaseConfig: Hashable, Sendable {
    public var projectId: String
    public var apiKey: String

    public init(projectId: String, apiKey: String) {
        self.projectId = projectId
        self.apiKey = apiKey
    }

    /// Reads Firebase.plist from `bundle`; nil when the build has none.
    public static func load(from bundle: Bundle = .main, resource: String = "Firebase") -> FirebaseConfig? {
        guard let url = bundle.url(forResource: resource, withExtension: "plist") else { return nil }
        return load(contentsOf: url)
    }

    public static func load(contentsOf url: URL) -> FirebaseConfig? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let projectId = plist["ProjectID"] as? String, !projectId.isEmpty,
              let apiKey = plist["APIKey"] as? String, !apiKey.isEmpty
        else { return nil }
        return FirebaseConfig(projectId: projectId, apiKey: apiKey)
    }
}

/// A Firebase user's tokens: the ID token Firestore takes, and the refresh token that renews it.
public struct AuthTokens: Codable, Hashable, Sendable {
    public var uid: String
    public var idToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(uid: String, idToken: String, refreshToken: String, expiresAt: Date) {
        self.uid = uid
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Where the tokens are kept between launches.
public protocol TokenStore: Sendable {
    func load() -> AuthTokens?
    /// nil removes them (signed out).
    func save(_ tokens: AuthTokens?)
}

/// For tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?

    public init(_ tokens: AuthTokens? = nil) { self.tokens = tokens }

    public func load() -> AuthTokens? { lock.withLock { tokens } }
    public func save(_ tokens: AuthTokens?) { lock.withLock { self.tokens = tokens } }
}

/// The app's store: one generic-password item in the Keychain. Readable after the first unlock,
/// so background refreshes work while the phone is locked; never synced or backed up elsewhere.
public struct KeychainTokenStore: TokenStore {
    public var service: String
    public var account: String

    public init(service: String = "dev.stow.ios.firebase", account: String = "tokens") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> AuthTokens? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    public func save(_ tokens: AuthTokens?) {
        SecItemDelete(query as CFDictionary)
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Firebase anonymous sign-in over REST (Identity Toolkit and Secure Token), without the SDK.
public actor FirebaseAuth {
    public let config: FirebaseConfig
    private let http: HTTPClient
    private let store: TokenStore
    private var tokens: AuthTokens?
    private var refreshing: Task<AuthTokens, Error>?

    /// Renew this long before the ID token runs out (an hour after it was issued).
    static let refreshMargin: TimeInterval = 5 * 60

    public init(config: FirebaseConfig, session: URLSession, store: TokenStore, firebaseGuard: FirebaseGuard? = nil) {
        self.config = config
        self.http = HTTPClient(session: session, firebaseGuard: firebaseGuard)
        self.store = store
        self.tokens = store.load()
    }

    public var uid: String? { tokens?.uid }

    /// This phone's user, signing up anonymously the first time.
    @discardableResult
    public func signIn() async throws -> String {
        if let tokens { return tokens.uid }
        var request = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(Self.escape(config.apiKey))")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["returnSecureToken": true])
        let (data, status) = try await http.send(request)
        struct Response: Decodable {
            var idToken: String
            var refreshToken: String
            var expiresIn: String?
            var localId: String
        }
        guard status == 200, let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw StowError.server("Firebase sign-in failed (HTTP \(status)): \(HTTPClient.message(from: data))")
        }
        let signedIn = AuthTokens(uid: response.localId, idToken: response.idToken, refreshToken: response.refreshToken,
                                  expiresAt: .now.addingTimeInterval(TimeInterval(response.expiresIn ?? "3600") ?? 3600))
        set(signedIn)
        return signedIn.uid
    }

    /// A current ID token, renewed when it's about to run out (or when `forceRefresh`).
    /// Throws `.notPaired` when there's no user (signed out, or Firebase deleted it).
    public func idToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw StowError.notPaired }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return current.idToken }
        if let refreshing { return try await refreshing.value.idToken }
        let task = Task { try await self.refresh(current) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value.idToken
    }

    public func signOut() {
        refreshing?.cancel()
        refreshing = nil
        set(nil)
    }

    private func refresh(_ current: AuthTokens) async throws -> AuthTokens {
        var request = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(Self.escape(config.apiKey))")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(Self.escape(current.refreshToken))".utf8)
        let (data, status) = try await http.send(request)
        struct Response: Decodable {
            var id_token: String
            var refresh_token: String
            var expires_in: String?
            var user_id: String?
        }
        if status == 400 || status == 401 || status == 403 {
            // TOKEN_EXPIRED, USER_DISABLED, USER_NOT_FOUND, INVALID_REFRESH_TOKEN: this user is gone for good.
            let message = HTTPClient.message(from: data)
            if ["TOKEN_EXPIRED", "USER_DISABLED", "USER_NOT_FOUND", "INVALID_REFRESH_TOKEN", "INVALID_GRANT_TYPE"].contains(where: message.contains) {
                set(nil)
                throw StowError.notPaired
            }
        }
        guard status == 200, let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw StowError.server("Firebase couldn't renew the sign-in (HTTP \(status)): \(HTTPClient.message(from: data))")
        }
        let renewed = AuthTokens(uid: response.user_id ?? current.uid, idToken: response.id_token, refreshToken: response.refresh_token,
                                 expiresAt: .now.addingTimeInterval(TimeInterval(response.expires_in ?? "3600") ?? 3600))
        // Signed out while this was under way: don't bring the user back.
        guard tokens?.refreshToken == current.refreshToken else { throw StowError.notPaired }
        set(renewed)
        return renewed
    }

    private func set(_ tokens: AuthTokens?) {
        self.tokens = tokens
        store.save(tokens)
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? text
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved characters: everything else is percent-encoded (URLComponents leaves '+' alone).
    static let urlUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// Firebase only in Mac mode: the Repository closes the guard when the app leaves it, and any
/// request still on its way is refused.
///
/// Each time it closes, the Remotes made before are retired. A retired Remote's request (work it
/// started in Mac mode and is finishing: a pull waiting for the Mac, a pairing's poll) is refused
/// quietly with `CancellationError`. Any other request while closed comes from code that reached
/// Firebase outside Mac mode: refused, and in debug builds an assertion fails.
public final class FirebaseGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var mode: AppMode
    /// Bumped each time the guard closes.
    private var era = 0

    public init(mode: AppMode = .mac) {
        self.mode = mode
    }

    public func set(_ mode: AppMode) {
        lock.withLock {
            if self.mode == .mac, mode != .mac { era += 1 }
            self.mode = mode
        }
    }

    public var isOpen: Bool { lock.withLock { mode == .mac } }

    /// For a client made now: the era it belongs to while open, nil while closed.
    var openEra: Int? { lock.withLock { mode == .mac ? era : nil } }

    /// Throws `CancellationError` for a retired client (`era` from before the guard last closed),
    /// and `.notPaired` (failing an assertion in debug builds) for any other request outside Mac mode.
    public func check(era opened: Int? = nil) throws {
        let (open, current) = lock.withLock { (mode == .mac, era) }
        if let opened, opened != current { throw CancellationError() }
        guard open else {
            #if DEBUG
            assertionFailure("FIREBASE TOUCHED in standalone")
            #endif
            throw StowError.notPaired
        }
    }
}

/// URLSession for Google's APIs.
struct HTTPClient: Sendable {
    let session: URLSession
    var firebaseGuard: FirebaseGuard?
    /// The guard's era when this client was made (nil: made while closed, or no guard).
    let era: Int?

    init(session: URLSession, firebaseGuard: FirebaseGuard? = nil) {
        self.session = session
        self.firebaseGuard = firebaseGuard
        era = firebaseGuard?.openEra
    }

    /// Throws `.network` only for transport failures; HTTP errors come back as the status.
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        try firebaseGuard?.check(era: era)
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StowError.network(error.localizedDescription)
        }
    }

    /// Google's `{"error": {"message": …}}`, or the start of the body.
    static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let description = object["error_description"] as? String { return description }
            if let error = object["error"] as? String { return error }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    /// Google's `error.status`, e.g. PERMISSION_DENIED.
    static func status(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["status"] as? String
    }

    /// An ephemeral session: no cookies, no cache.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }
}
