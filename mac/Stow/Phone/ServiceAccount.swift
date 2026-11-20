import Foundation
import Security

/// The Firebase project's service-account key (Project settings › Service accounts › Generate
/// new private key). The Mac signs in with it, so Firestore's security rules don't apply to it.
/// SecKey is immutable and thread-safe.
struct ServiceAccount: @unchecked Sendable {
    let projectId: String
    let clientEmail: String
    let privateKeyId: String
    let tokenURI: URL
    let privateKey: SecKey

    static let scopes = ["https://www.googleapis.com/auth/datastore",
                         "https://www.googleapis.com/auth/firebase.messaging"]

    /// Throws `.parse` when `data` isn't a service-account key.
    init(json data: Data) throws {
        struct Key: Decodable {
            var type: String?
            var project_id: String
            var private_key_id: String?
            var private_key: String
            var client_email: String
            var token_uri: String?
        }
        guard let key = try? JSONDecoder().decode(Key.self, from: data), key.type == nil || key.type == "service_account" else {
            throw StowError.parse("That isn't a Firebase service-account key (a .json file from Project settings › Service accounts).")
        }
        projectId = key.project_id
        clientEmail = key.client_email
        privateKeyId = key.private_key_id ?? ""
        tokenURI = key.token_uri.flatMap(URL.init(string:)) ?? URL(string: "https://oauth2.googleapis.com/token")!
        privateKey = try Self.rsaKey(pem: key.private_key)
    }

    /// A signed JWT asking `tokenURI` for an access token (RFC 7523).
    func assertion(scopes: [String] = ServiceAccount.scopes, now: Date = .now) throws -> String {
        let header = ["alg": "RS256", "typ": "JWT", "kid": privateKeyId]
        let issued = Int(now.timeIntervalSince1970)
        let claims: [String: Any] = ["iss": clientEmail, "scope": scopes.joined(separator: " "),
                                     "aud": tokenURI.absoluteString, "iat": issued, "exp": issued + 3600]
        let input = try [header as [String: Any], claims]
            .map { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys).base64URLEncoded }
            .joined(separator: ".")
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(input.utf8) as CFData, &error) as Data? else {
            throw StowError.parse("Couldn't sign with the Firebase key: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return input + "." + signature.base64URLEncoded
    }

    /// The key from "-----BEGIN PRIVATE KEY-----" (PKCS #8) PEM.
    static func rsaKey(pem: String) throws -> SecKey {
        let base64 = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: base64), let pkcs1 = DER.pkcs1(fromPKCS8: der) else {
            throw StowError.parse("The Firebase key's private_key isn't a PKCS #8 RSA key.")
        }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw StowError.parse("The Firebase key's private_key can't be used: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return key
    }
}

/// Just enough DER to unwrap a PKCS #8 PrivateKeyInfo: SEQUENCE { INTEGER version,
/// SEQUENCE algorithm, OCTET STRING privateKey }.
enum DER {
    static func pkcs1(fromPKCS8 der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let outer = element(bytes, at: 0), outer.tag == 0x30 else { return nil }
        guard let version = element(bytes, at: outer.content.lowerBound), version.tag == 0x02,
              let algorithm = element(bytes, at: version.end), algorithm.tag == 0x30,
              let key = element(bytes, at: algorithm.end), key.tag == 0x04 else { return nil }
        return Data(bytes[key.content])
    }

    private static func element(_ bytes: [UInt8], at offset: Int) -> (tag: UInt8, content: Range<Int>, end: Int)? {
        guard offset + 1 < bytes.count else { return nil }
        var index = offset + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard index + length <= bytes.count else { return nil }
        return (bytes[offset], index..<index + length, index + length)
    }
}

/// Access tokens for the service account, cached until shortly before they expire.
actor GoogleAuth {
    private let account: ServiceAccount
    private let http: FirebaseHTTP
    private let scopes: [String]
    private var token: (value: String, expires: Date)?

    init(account: ServiceAccount, http: FirebaseHTTP, scopes: [String] = ServiceAccount.scopes) {
        self.account = account
        self.http = http
        self.scopes = scopes
    }

    /// Throws `.network`, or `.parse` when Google rejects the key (e.g. it was deleted).
    func accessToken() async throws -> String {
        if let token, token.expires > .now.addingTimeInterval(60) { return token.value }
        var request = URLRequest(url: account.tokenURI)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let assertion = try account.assertion(scopes: scopes)
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        let (data, status) = try await http.send(request)
        struct Response: Decodable {
            var access_token: String
            var expires_in: Double?
        }
        guard status == 200, let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw StowError.parse("Google didn't accept the Firebase key (HTTP \(status)): \(FirebaseHTTP.message(from: data))")
        }
        token = (response.access_token, .now.addingTimeInterval(response.expires_in ?? 3600))
        return response.access_token
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
