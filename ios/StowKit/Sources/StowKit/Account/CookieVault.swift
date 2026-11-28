import Foundation
import Security

/// Where the phone's YouTube sign-in (a cookies.txt) is kept. Only the vault holds cookie
/// values; standalone.json holds only whether there is a sign-in.
public protocol CookieVault: Sendable {
    func load() -> Data?
    /// nil deletes it. Throws when the store refuses, so a sign-in that wasn't kept isn't reported as one.
    func save(_ data: Data?) throws
}

/// The Keychain refused to keep (or delete) the sign-in.
public struct CookieVaultError: Error, Equatable, LocalizedError {
    public var status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? { "Couldn't keep the sign-in on this phone (Keychain error \(status))." }
}

/// One generic-password Keychain item, readable after the first unlock (background refreshes
/// run while the phone is locked) and never synced or moved to another device.
public struct KeychainCookieVault: CookieVault {
    public var service: String
    public var account: String

    public init(service: String = "dev.stow.ios.youtube", account: String = "cookies") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> Data? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func save(_ data: Data?) throws {
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw CookieVaultError(status: deleted) }
        guard let data else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw CookieVaultError(status: added) }
    }
}

/// For tests and previews. `failSaves` makes saving throw, as a Keychain that refuses would.
public final class InMemoryCookieVault: CookieVault, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var failing = false

    public init(_ data: Data? = nil) { self.data = data }

    public var failSaves: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    public func load() -> Data? { lock.withLock { data } }

    public func save(_ data: Data?) throws {
        try lock.withLock {
            if failing { throw CookieVaultError(status: errSecNotAvailable) }
            self.data = data
        }
    }
}
