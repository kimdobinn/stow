import CryptoKit
import Foundation

/// Opens what the Mac sealed with CryptoKit's ChaChaPoly: 12-byte nonce, ciphertext, 16-byte tag.
public enum Crypto {
    public static func open(_ sealed: Data, key: Data) throws -> Data {
        guard sealed.count > 28 else { throw StowError.parse("Sealed data is too short") }
        guard key.count == 32 else { throw StowError.parse("The pairing key isn't 32 bytes") }
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: SymmetricKey(data: key))
        } catch {
            throw StowError.parse("Couldn't decrypt what the Mac shared. Pair this phone again.")
        }
    }

    /// The Firestore form: standard base64 of the combined box.
    public static func open(base64 sealed: String, key: Data) throws -> Data {
        guard let data = Data(base64Encoded: sealed, options: .ignoreUnknownCharacters) else {
            throw StowError.parse("Sealed data isn't base64")
        }
        return try open(data, key: key)
    }
}

extension Data {
    /// Base64url without padding, as the pairing QR code carries the key.
    public init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    public var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What the Mac's pairing QR code holds: stow://pair?p=<project>&c=<code>&k=<key>.
public struct Invite: Hashable, Sendable {
    public var projectId: String
    /// One-time code the pairing request is filed under.
    public var code: String
    /// The pairing key, base64url.
    public var key: String

    public init(projectId: String, code: String, key: String) {
        self.projectId = projectId
        self.code = code
        self.key = key
    }

    /// nil unless `text` is a stow://pair link with all three parts.
    public static func parse(_ text: String) -> Invite? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "stow", components.host == "pair" else { return nil }
        func item(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        // Firestore's rules refuse pairing codes shorter than 32 characters; the Mac's are longer.
        guard let project = item("p"), let code = item("c"), code.count >= 32, let key = item("k") else { return nil }
        return Invite(projectId: project, code: code, key: key)
    }
}
