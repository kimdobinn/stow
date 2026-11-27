import Foundation

/// Loose reading of JSON objects, the way the Android app reads them with org.json: missing,
/// null, empty and "null" strings all count as absent, and numbers are read whatever their type.
struct JSONObject {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    init?(any: Any?) {
        guard let raw = any as? [String: Any] else { return nil }
        self.raw = raw
    }

    /// Parses `text`; throws when it isn't a JSON object.
    init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }

    init(parsing data: Data) throws {
        guard let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw StowError.parse("Expected a JSON object")
        }
        self.raw = raw
    }

    func has(_ key: String) -> Bool { raw[key] != nil }

    func isNull(_ key: String) -> Bool { raw[key] == nil || raw[key] is NSNull }

    /// A non-empty string other than "null" (numbers are written out, as org.json's optString does).
    func string(_ key: String) -> String? {
        switch raw[key] {
        case let value as String: return value.isEmpty || value == "null" ? nil : value
        case let value as NSNumber where !Self.isBool(value): return value.stringValue
        default: return nil
        }
    }

    func number(_ key: String) -> Double? {
        switch raw[key] {
        case let value as NSNumber where !Self.isBool(value): return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    /// Whole number, truncated like Kotlin's toLong().
    func int(_ key: String) -> Int? {
        guard let value = number(key), value.isFinite else { return nil }
        return Int(value)
    }

    func bool(_ key: String) -> Bool {
        switch raw[key] {
        case let value as NSNumber: return value.boolValue
        case let value as String: return value.lowercased() == "true"
        default: return false
        }
    }

    func object(_ key: String) -> JSONObject? { JSONObject(any: raw[key]) }

    func array(_ key: String) -> [Any]? { raw[key] as? [Any] }

    func objects(_ key: String) -> [JSONObject]? { array(key)?.compactMap { JSONObject(any: $0) } }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

extension Date {
    /// Seconds since 1970, as yt-dlp and the Mac write them.
    init(epochSeconds: Double) {
        self.init(timeIntervalSince1970: epochSeconds)
    }
}
