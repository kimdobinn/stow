import Foundation

/// A Firestore field value, in the REST API's JSON form ({"stringValue": "…"} and so on).
public enum FirestoreValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    /// RFC 3339 as Firestore sent it (it carries microseconds or nanoseconds), so it can go back exactly.
    case timestamp(String)
    case bytes(Data)
    case array([FirestoreValue])
    case map([String: FirestoreValue])

    public static func date(_ date: Date) -> FirestoreValue { .timestamp(FirestoreTime.string(from: date)) }

    public static func optional(_ string: String?) -> FirestoreValue { string.map(FirestoreValue.string) ?? .null }

    // Reading

    public var isNull: Bool { self == .null }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var map: [String: FirestoreValue]? { if case .map(let value) = self { value } else { nil } }
    public var array: [FirestoreValue]? { if case .array(let value) = self { value } else { nil } }
    public var timestamp: String? { if case .timestamp(let value) = self { value } else { nil } }

    /// Integers and doubles alike (the Mac writes durations as doubles), truncated.
    public var int: Int? {
        switch self {
        case .int(let value): Int(value)
        case .double(let value) where value.isFinite: Int(value)
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    public var date: Date? { timestamp.flatMap(FirestoreTime.date(from:)) }

    // JSON

    public var json: [String: Any] {
        switch self {
        case .null: ["nullValue": NSNull()]
        case .bool(let value): ["booleanValue": value]
        // int64 travels as a string, so it survives JavaScript-sized numbers.
        case .int(let value): ["integerValue": String(value)]
        case .double(let value): ["doubleValue": value]
        case .string(let value): ["stringValue": value]
        case .timestamp(let value): ["timestampValue": value]
        case .bytes(let value): ["bytesValue": value.base64EncodedString()]
        case .array(let values): ["arrayValue": ["values": values.map(\.json)]]
        case .map(let fields): ["mapValue": ["fields": fields.mapValues(\.json)]]
        }
    }

    /// Unknown kinds (references, geo points) read as null.
    public init(json: Any) {
        guard let object = json as? [String: Any], let (kind, value) = object.first else {
            self = .null
            return
        }
        switch kind {
        case "booleanValue": self = .bool((value as? NSNumber)?.boolValue ?? false)
        case "integerValue":
            if let text = value as? String, let number = Int64(text) { self = .int(number) }
            else if let number = value as? NSNumber { self = .int(number.int64Value) }
            else { self = .null }
        case "doubleValue":
            if let number = value as? NSNumber { self = .double(number.doubleValue) }
            // NaN and the infinities come as strings.
            else if let text = value as? String, let number = Double(text) { self = .double(number) }
            else { self = .null }
        case "stringValue": self = .string(value as? String ?? "")
        case "timestampValue": self = .timestamp(value as? String ?? "")
        case "bytesValue": self = .bytes((value as? String).flatMap { Data(base64Encoded: $0) } ?? Data())
        case "arrayValue":
            let values = (value as? [String: Any])?["values"] as? [Any] ?? []
            self = .array(values.map(FirestoreValue.init(json:)))
        case "mapValue":
            let fields = (value as? [String: Any])?["fields"] as? [String: Any] ?? [:]
            self = .map(fields.mapValues(FirestoreValue.init(json:)))
        default: self = .null
        }
    }
}

extension FirestoreValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(nilLiteral: ()) { self = .null }
}

/// A Firestore document: its id (the last path segment) and fields.
public struct FirestoreDocument: Hashable, Sendable {
    /// e.g. "videos/dQw4w9WgXcQ".
    public var path: String
    public var fields: [String: FirestoreValue]
    public var updateTime: String?

    public init(path: String, fields: [String: FirestoreValue], updateTime: String? = nil) {
        self.path = path
        self.fields = fields
        self.updateTime = updateTime
    }

    public var id: String { String(path.split(separator: "/").last ?? "") }

    public subscript(_ field: String) -> FirestoreValue? { fields[field] }

    /// From the REST form; `name` is the full resource name (projects/…/documents/videos/abc).
    init?(json: Any) {
        guard let object = json as? [String: Any], let name = object["name"] as? String else { return nil }
        if let range = name.range(of: "/documents/") {
            path = String(name[range.upperBound...])
        } else {
            path = name
        }
        fields = (object["fields"] as? [String: Any] ?? [:]).mapValues(FirestoreValue.init(json:))
        updateTime = object["updateTime"] as? String
    }
}

/// Firestore's RFC 3339 timestamps, with any number of fractional digits.
enum FirestoreTime {
    static func string(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func date(from text: String) -> Date? {
        // Foundation's parser takes at most milliseconds reliably: split off the fraction and
        // add it back, so microseconds and nanoseconds parse too.
        var base = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text.index(after: dot)
            let end = text[afterDot...].firstIndex { !$0.isNumber } ?? text.endIndex
            fraction = Double("0." + text[afterDot..<end]) ?? 0
            base = String(text[..<dot]) + String(text[end...])
        }
        guard let date = try? Date(base, strategy: Date.ISO8601FormatStyle()) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}
