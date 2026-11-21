import CryptoKit
import Foundation
import Testing
@testable import Stow

/// The key 0x00…0x1f, shared with the Android tests.
let remoteTestKey = SymmetricKey(data: Data(0..<32))
let remoteTestNow = Date(timeIntervalSince1970: 1_700_000_000)

/// A request signed like the phone signs it.
func signedRequest(_ method: String = "GET", _ path: String = "/v1/state", body: String = "",
                   key: SymmetricKey = remoteTestKey, at time: Date = remoteTestNow,
                   nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) -> RemoteHTTPRequest {
    let millis = String(Int64((time.timeIntervalSince1970 * 1000).rounded()))
    let data = Data(body.utf8)
    let signature = RemoteAuth.signature(key: key, method: method, path: path, time: millis, nonce: nonce, body: data)
    return RemoteHTTPRequest(method: method, path: path,
                             headers: ["x-stow-time": millis, "x-stow-nonce": nonce, "x-stow-signature": signature,
                                       "content-length": String(data.count)],
                             body: data)
}

struct RemoteAuthTests {
    /// Android's signer must produce exactly this.
    @Test func fixedTestVector() {
        let body = Data(#"{"action":"next"}"#.utf8)
        let canonical = RemoteAuth.canonical(method: "POST", path: "/v1/action", time: "1700000000000",
                                             nonce: "000102030405060708090a0b0c0d0e0f", body: body)
        #expect(String(decoding: canonical, as: UTF8.self) == """
            POST
            /v1/action
            1700000000000
            000102030405060708090a0b0c0d0e0f
            282c6f52c450254aa3d4a831f1aa199bd994919d2bb8ec7d6f7e9f24930740dc
            """)
        #expect(RemoteAuth.signature(key: remoteTestKey, method: "POST", path: "/v1/action", time: "1700000000000",
                                     nonce: "000102030405060708090a0b0c0d0e0f", body: body)
                == "PI4O5q6x-pwCSpqtifcwo-3o8yaRdPW8i2hdhCKcCDE")
    }

    @Test func emptyBodyHashesTheEmptyInput() {
        let canonical = String(decoding: RemoteAuth.canonical(method: "GET", path: "/v1/state", time: "1", nonce: "n", body: Data()),
                               as: UTF8.self)
        #expect(canonical.hasSuffix("\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
    }

    @Test func acceptsAValidRequestOnce() {
        var nonces = RemoteNonceCache()
        let request = signedRequest("POST", "/v1/action", body: #"{"action":"next"}"#)
        #expect(RemoteAuth.failure(of: request, key: remoteTestKey, now: remoteTestNow, nonces: &nonces) == nil)
        #expect(RemoteAuth.failure(of: request, key: remoteTestKey, now: remoteTestNow.addingTimeInterval(1), nonces: &nonces)
                == "Replayed request (nonce already used).")
    }

    @Test func rejectsTheWrongKey() {
        var nonces = RemoteNonceCache()
        let request = signedRequest(key: SymmetricKey(data: Data(repeating: 7, count: 32)))
        #expect(RemoteAuth.failure(of: request, key: remoteTestKey, now: remoteTestNow, nonces: &nonces) == "Bad signature.")
    }

    @Test func rejectsTimesMoreThanTwoMinutesOff() {
        var nonces = RemoteNonceCache()
        #expect(RemoteAuth.failure(of: signedRequest(at: remoteTestNow.addingTimeInterval(-120)), key: remoteTestKey,
                                   now: remoteTestNow, nonces: &nonces) == nil)
        let stale = RemoteAuth.failure(of: signedRequest(at: remoteTestNow.addingTimeInterval(-121)), key: remoteTestKey,
                                       now: remoteTestNow, nonces: &nonces)
        #expect(stale?.contains("121 s off") == true)
        let ahead = RemoteAuth.failure(of: signedRequest(at: remoteTestNow.addingTimeInterval(200)), key: remoteTestKey,
                                       now: remoteTestNow, nonces: &nonces)
        #expect(ahead?.contains("-200 s off") == true)
    }

    @Test func rejectsATamperedBodyPathOrMethod() {
        var nonces = RemoteNonceCache()
        var body = signedRequest("POST", "/v1/action", body: #"{"action":"next"}"#)
        body.body = Data(#"{"action":"stop"}"#.utf8)
        #expect(RemoteAuth.failure(of: body, key: remoteTestKey, now: remoteTestNow, nonces: &nonces) == "Bad signature.")
        var path = signedRequest()
        path.path = "/v1/choices"
        #expect(RemoteAuth.failure(of: path, key: remoteTestKey, now: remoteTestNow, nonces: &nonces) == "Bad signature.")
        var method = signedRequest()
        method.method = "POST"
        #expect(RemoteAuth.failure(of: method, key: remoteTestKey, now: remoteTestNow, nonces: &nonces) == "Bad signature.")
        var time = signedRequest()
        time.headers["x-stow-time"] = String(Int64(remoteTestNow.timeIntervalSince1970 * 1000) + 1)
        #expect(RemoteAuth.failure(of: time, key: remoteTestKey, now: remoteTestNow, nonces: &nonces) == "Bad signature.")
    }

    @Test func rejectsMissingOrMalformedHeaders() {
        var nonces = RemoteNonceCache()
        func failure(_ header: String, _ value: String?) -> String? {
            var request = signedRequest()
            request.headers[header] = value
            return RemoteAuth.failure(of: request, key: remoteTestKey, now: remoteTestNow, nonces: &nonces)
        }
        #expect(failure("x-stow-signature", nil)?.hasPrefix("Missing") == true)
        #expect(failure("x-stow-time", "17e11") == "Malformed X-Stow-Time.")
        #expect(failure("x-stow-nonce", "ABCDEF0123456789ABCDEF0123456789") == "Malformed X-Stow-Nonce.")
        #expect(failure("x-stow-nonce", "abc") == "Malformed X-Stow-Nonce.")
        #expect(failure("x-stow-signature", "not base64!") == "Malformed X-Stow-Signature.")
        #expect(failure("x-stow-signature", "AAAA") == "Bad signature.")
    }

    @Test func nonceCacheForgetsAfterFiveMinutes() {
        var nonces = RemoteNonceCache()
        let first = nonces.insert("a", at: remoteTestNow)
        let again = nonces.insert("a", at: remoteTestNow.addingTimeInterval(299))
        let later = nonces.insert("a", at: remoteTestNow.addingTimeInterval(300))
        #expect(first && !again && later)
    }

    @Test func base64URLDecodesWithOrWithoutPadding() {
        #expect(Data(base64URLEncoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8") == Data(0..<32))
        #expect(Data(base64URLEncoded: "-_8=") == Data([0xfb, 0xff]))
        #expect(Data(base64URLEncoded: "-_8") == Data([0xfb, 0xff]))
        #expect(Data(base64URLEncoded: "a+b/") == nil)
    }
}
