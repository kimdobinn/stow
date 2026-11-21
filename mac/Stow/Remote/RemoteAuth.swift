import CryptoKit
import Foundation

/// Every remote request is signed with the pairing key, which only the paired phones have:
/// X-Stow-Signature = base64url (no padding) of HMAC-SHA256(key, canonical), where canonical is
/// METHOD, PATH, X-Stow-Time (unix ms), X-Stow-Nonce (32 lowercase hex) and the body's
/// lowercase hex SHA-256, joined by "\n". A request too far off the Mac's clock, or replayed, fails.
enum RemoteAuth {
    static let timeHeader = "X-Stow-Time"
    static let nonceHeader = "X-Stow-Nonce"
    static let signatureHeader = "X-Stow-Signature"
    static let maxClockSkew: TimeInterval = 120

    static func canonical(method: String, path: String, time: String, nonce: String, body: Data) -> Data {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data([method, path, time, nonce, bodyHash].joined(separator: "\n").utf8)
    }

    static func signature(key: SymmetricKey, method: String, path: String, time: String, nonce: String, body: Data) -> String {
        let canonical = canonical(method: method, path: path, time: time, nonce: nonce, body: body)
        return Data(HMAC<SHA256>.authenticationCode(for: canonical, using: key)).base64URLEncoded
    }

    /// Nil when `request` is signed with `key`, recent and new (its nonce is then remembered);
    /// otherwise why not.
    static func failure(of request: RemoteHTTPRequest, key: SymmetricKey, now: Date,
                        nonces: inout RemoteNonceCache) -> String? {
        guard let time = request.header(timeHeader), let nonce = request.header(nonceHeader),
              let signature = request.header(signatureHeader) else {
            return "Missing \(timeHeader), \(nonceHeader) or \(signatureHeader)."
        }
        guard !time.isEmpty, time.count <= 16, time.allSatisfy({ ("0"..."9").contains($0) }), let millis = Int64(time) else {
            return "Malformed \(timeHeader)."
        }
        guard nonce.count == 32, nonce.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return "Malformed \(nonceHeader)."
        }
        guard let code = Data(base64URLEncoded: signature) else { return "Malformed \(signatureHeader)." }
        let canonical = canonical(method: request.method, path: request.path, time: time, nonce: nonce, body: request.body)
        guard HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: canonical, using: key) else {
            return "Bad signature."
        }
        let skew = now.timeIntervalSince1970 - Double(millis) / 1000
        guard abs(skew) <= maxClockSkew else {
            return "\(timeHeader) is \(Int(skew.rounded())) s off the Mac's clock (at most \(Int(maxClockSkew)) s)."
        }
        guard nonces.insert(nonce, at: now) else { return "Replayed request (nonce already used)." }
        return nil
    }
}

/// Nonces of accepted requests from the last 5 minutes. A request older than that already fails
/// the clock check, so forgetting them then is safe.
struct RemoteNonceCache {
    static let lifetime: TimeInterval = 5 * 60
    /// Far more than a phone polling every second sends in 5 minutes.
    static let capacity = 10_000

    private var seen: [String: Date] = [:]

    /// False when `nonce` was already used.
    mutating func insert(_ nonce: String, at now: Date) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.lifetime }
        guard seen[nonce] == nil else { return false }
        if seen.count >= Self.capacity, let oldest = seen.min(by: { $0.value < $1.value }) {
            seen[oldest.key] = nil
        }
        seen[nonce] = now
        return true
    }
}

/// One `RemoteNonceCache` for every run, so a request captured in one run can't be replayed into
/// the next while it is still within the clock window. Used on the main actor only.
final class RemoteNonceStore {
    var cache = RemoteNonceCache()
}

extension Data {
    /// Base64url with or without padding; nil when it isn't.
    init?(base64URLEncoded text: String) {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=") }) else {
            return nil
        }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
