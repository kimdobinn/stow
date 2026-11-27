import Foundation

/// A dotted version such as "0.2.0" (Stow) or "2026.11.23" (yt-dlp), compared number by number;
/// missing parts count as 0, so "0.2" == "0.2.0".
struct DottedVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let parts: [Int]
    /// As written, without any tag prefix.
    let description: String

    /// Accepts "0.2.0", "v0.2.0" and tags like "mac-v0.2.0"; nil for anything else.
    init?(_ text: String, prefix: String = "") {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty {
            guard text.hasPrefix(prefix) else { return nil }
            text.removeFirst(prefix.count)
        } else if text.hasPrefix("v") {
            text.removeFirst()
        }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 6 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), piece.allSatisfy(\.isNumber), let number = Int(piece) else { return nil }
            parts.append(number)
        }
        self.parts = parts
        description = text
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    /// The running app's CFBundleShortVersionString.
    static var running: DottedVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { DottedVersion($0) }
    }
}

extension DottedVersion: Codable {
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = DottedVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a version: \(text)"))
        }
        self = version
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
