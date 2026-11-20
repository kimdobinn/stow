import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation

/// The key that encrypts what only the phones may read (the YouTube cookies). It never leaves
/// the Mac except inside the pairing QR code, so Google only ever stores ciphertext.
struct PairingKey: Sendable {
    let key: SymmetricKey

    /// Reads the key, creating it (0600) the first time.
    static func loadOrCreate(at file: URL) throws -> PairingKey {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 {
            return PairingKey(key: SymmetricKey(data: data))
        }
        let key = SymmetricKey(size: .bits256)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return PairingKey(key: key)
    }

    /// ChaChaPoly combined form: 12-byte nonce, ciphertext, 16-byte tag.
    func seal(_ data: Data) throws -> Data {
        try ChaChaPoly.seal(data, using: key).combined
    }

    func open(_ sealed: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
    }

    var base64URL: String { key.withUnsafeBytes { Data($0) }.base64URLEncoded }
}

/// What the pairing QR code holds: stow://pair?p=<project>&c=<code>&k=<key>. The phone files a
/// request under the one-time code; the key lets it decrypt the cookies.
struct PairingInvite: Equatable, Sendable {
    var projectId: String
    /// 256 random bits, so nobody can guess it and pair in the meantime.
    var code: String
    var keyBase64URL: String

    static func make(projectId: String, key: PairingKey) -> PairingInvite {
        let code = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URLEncoded
        return PairingInvite(projectId: projectId, code: code, keyBase64URL: key.base64URL)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "stow"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "p", value: projectId), URLQueryItem(name: "c", value: code),
                                 URLQueryItem(name: "k", value: keyBase64URL)]
        return components.url!
    }

    /// A crisp QR code of `url`, `size` points square.
    func qrImage(size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (size * 2 / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
        image.addRepresentation(representation)
        return image
    }
}
