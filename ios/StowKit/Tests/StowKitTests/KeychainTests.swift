import Foundation
import Security
import Testing
@testable import StowKit

// Only on iOS: on a Mac, `swift test` would reach the login keychain. A test bundle without a
// host app has no keychain entitlement (errSecMissingEntitlement), so it runs only where it can.
#if os(iOS)
private var keychainAvailable: Bool {
    let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.stow.ios.tests.probe",
                                kSecAttrAccount as String: "probe", kSecValueData as String: Data("x".utf8)]
    let status = SecItemAdd(probe as CFDictionary, nil)
    SecItemDelete(probe as CFDictionary)
    return status == errSecSuccess || status == errSecDuplicateItem
}

@Suite(.enabled(if: keychainAvailable, "This test host has no keychain entitlement"))
struct KeychainTests {

    @Test func savesReadsAndRemovesTheTokens() {
        let store = KeychainTokenStore(service: "dev.stow.ios.tests.\(UUID().uuidString)")
        #expect(store.load() == nil)
        let tokens = validTokens()
        store.save(tokens)
        #expect(store.load() == tokens)
        var renewed = tokens
        renewed.idToken = "id-token-2"
        store.save(renewed)
        #expect(store.load() == renewed)
        store.save(nil)
        #expect(store.load() == nil)
    }
}
#endif
