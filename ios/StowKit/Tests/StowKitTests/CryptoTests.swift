import CryptoKit
import Foundation
import Testing
@testable import StowKit

enum SealHelper {
    /// What the Mac does (PairingKey.seal): ChaChaPoly's combined box.
    static func seal(_ data: Data, key: Data) throws -> Data {
        try ChaChaPoly.seal(data, using: SymmetricKey(data: key)).combined
    }
}

@Suite struct CryptoTests {
    private let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

    @Test func opensWhatTheMacSealed() throws {
        let plain = Data(#"{"recommended":[],"subscriptions":[]}"#.utf8)
        let sealed = try SealHelper.seal(plain, key: key)
        #expect(try Crypto.open(sealed, key: key) == plain)
        #expect(try Crypto.open(base64: sealed.base64EncodedString(), key: key) == plain)
    }

    @Test func refusesTheWrongKeyOrTamperedData() throws {
        let sealed = try SealHelper.seal(Data("secret".utf8), key: key)
        let other = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        #expect(throws: StowError.self) { try Crypto.open(sealed, key: other) }
        var tampered = sealed
        tampered[14] ^= 0x01
        #expect(throws: StowError.self) { try Crypto.open(tampered, key: key) }
        #expect(throws: StowError.self) { try Crypto.open(Data(count: 20), key: key) }
        #expect(throws: StowError.self) { try Crypto.open(base64: "not base64!", key: key) }
    }

    @Test func theQRCodeKeyIsBase64URL() throws {
        // As the Mac writes it: no padding, '-' and '_'.
        let raw = Data([0xfb, 0xff, 0xfe] + Array(repeating: 0, count: 29))
        let text = raw.base64URLEncodedString
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        #expect(Data(base64URLEncoded: text) == raw)
        #expect(Data(base64URLEncoded: "-_8") == Data([0xfb, 0xff]))
    }

    @Test func parsesTheMacsInvite() throws {
        let code = Data(repeating: 7, count: 32).base64URLEncodedString
        let keyText = key.base64URLEncodedString
        let invite = try #require(Invite.parse(" stow://pair?p=stow-example&c=\(code)&k=\(keyText)\n"))
        #expect(invite == Invite(projectId: "stow-example", code: code, key: keyText))
        #expect(Data(base64URLEncoded: invite.key) == key)
    }

    @Test func rejectsOtherCodes() {
        #expect(Invite.parse("https://example.com/pair?p=a&c=b&k=c") == nil)
        #expect(Invite.parse("stow://remote?p=a&c=b&k=c") == nil)
        #expect(Invite.parse("stow://pair?p=a&c=b") == nil)
        #expect(Invite.parse("hello") == nil)
        #expect(Invite.parse("") == nil)
    }
}
