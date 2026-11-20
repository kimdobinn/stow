import Foundation

/// URLSession for Google's APIs (no cookies, no cache).
struct FirebaseHTTP: Sendable {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Throws `.network` only for transport failures; HTTP errors come back as the status.
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        do {
            let (data, response) = try await Self.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw StowError.network(error.localizedDescription)
        }
    }

    /// Google's `{"error": {"message": …}}`, or the start of the body.
    static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let description = object["error_description"] as? String { return description }
            if let error = object["error"] as? String { return error }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

/// A Firestore field value, in the REST API's JSON form ({"stringValue": "…"} and so on).
enum FirestoreValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// RFC 3339, kept as Firestore sent it (microseconds) so it can be sent back exactly.
    case timestamp(String)
    case array([FirestoreValue])
    case map([String: FirestoreValue])

    static func date(_ date: Date) -> FirestoreValue {
        .timestamp(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    static func optional(_ string: String?) -> FirestoreValue {
        string.map(FirestoreValue.string) ?? .null
    }

    var json: Any {
        switch self {
        case .null: ["nullValue": NSNull()]
        case .bool(let value): ["booleanValue": value]
        case .int(let value): ["integerValue": String(value)]
        case .double(let value): ["doubleValue": value]
        case .string(let value): ["stringValue": value]
        case .timestamp(let value): ["timestampValue": value]
        case .array(let values): ["arrayValue": ["values": values.map(\.json)]]
        case .map(let fields): ["mapValue": ["fields": fields.mapValues(\.json)]]
        }
    }

    init(json: Any) {
        guard let object = json as? [String: Any], let (kind, value) = object.first else {
            self = .null
            return
        }
        switch kind {
        case "booleanValue": self = .bool(value as? Bool ?? false)
        case "integerValue": self = .int(Int(value as? String ?? "") ?? (value as? Int) ?? 0)
        case "doubleValue": self = .double(value as? Double ?? 0)
        case "stringValue": self = .string(value as? String ?? "")
        case "timestampValue": self = .timestamp(value as? String ?? "")
        case "arrayValue":
            let values = (value as? [String: Any])?["values"] as? [Any] ?? []
            self = .array(values.map(FirestoreValue.init(json:)))
        case "mapValue":
            let fields = (value as? [String: Any])?["fields"] as? [String: Any] ?? [:]
            self = .map(fields.mapValues(FirestoreValue.init(json:)))
        default: self = .null
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var timestamp: String? { if case .timestamp(let value) = self { value } else { nil } }
    var map: [String: FirestoreValue]? { if case .map(let value) = self { value } else { nil } }

    var date: Date? {
        guard let timestamp else { return nil }
        return (try? Date(timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(timestamp, strategy: .iso8601))
    }
}

struct FirestoreDocument: Equatable, Sendable {
    /// The id, e.g. "dQw4w9WgXcQ" for videos/dQw4w9WgXcQ.
    var id: String
    var fields: [String: FirestoreValue]

    init(id: String, fields: [String: FirestoreValue]) {
        self.id = id
        self.fields = fields
    }

    init?(json: Any) {
        guard let object = json as? [String: Any], let name = object["name"] as? String else { return nil }
        id = String(name.split(separator: "/").last ?? "")
        fields = (object["fields"] as? [String: Any] ?? [:]).mapValues(FirestoreValue.init(json:))
    }
}

/// One write in a commit (all writes of a commit apply together or not at all).
enum FirestoreWrite: Sendable {
    /// Sets `fields` (only those: other fields of an existing document stay), creating the
    /// document if needed; `updatedAt` becomes the server's time when `stampsUpdatedAt`.
    case merge(path: String, fields: [String: FirestoreValue], stampsUpdatedAt: Bool = true)
    case delete(path: String)
}

/// Firestore's REST API for the project's (default) database, as the service account.
struct FirestoreREST: Sendable {
    let projectId: String
    /// A bearer token: the service account's, or (in the phone check) a Firebase user's ID token.
    let token: @Sendable () async throws -> String
    let http: FirebaseHTTP

    private var root: String { "projects/\(projectId)/databases/(default)/documents" }
    private var base: String { "https://firestore.googleapis.com/v1/\(root)" }

    /// nil when the document doesn't exist.
    func get(_ path: String) async throws -> FirestoreDocument? {
        let (data, status) = try await send("GET", "\(base)/\(path)")
        if status == 404 { return nil }
        try check(status, data, "read \(path)")
        return FirestoreDocument(json: try JSONSerialization.jsonObject(with: data))
    }

    /// Every document of a top-level collection (at most 300).
    func list(_ collection: String) async throws -> [FirestoreDocument] {
        let (data, status) = try await send("GET", "\(base)/\(collection)?pageSize=300")
        try check(status, data, "list \(collection)")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["documents"] as? [Any] ?? []).compactMap(FirestoreDocument.init(json:))
    }

    /// Documents of `collection` whose `updatedAt` is after `after` (all when nil), oldest change first.
    func changed(_ collection: String, after: String?, limit: Int = 300) async throws -> [FirestoreDocument] {
        var query: [String: Any] = [
            "from": [["collectionId": collection]],
            "orderBy": [["field": ["fieldPath": "updatedAt"], "direction": "ASCENDING"]],
            "limit": limit,
        ]
        if let after {
            query["where"] = ["fieldFilter": ["field": ["fieldPath": "updatedAt"], "op": "GREATER_THAN",
                                              "value": FirestoreValue.timestamp(after).json]]
        }
        let (data, status) = try await send("POST", "\(base):runQuery", body: ["structuredQuery": query])
        try check(status, data, "query \(collection)")
        let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return results.compactMap { $0["document"] }.compactMap(FirestoreDocument.init(json:))
    }

    func commit(_ writes: [FirestoreWrite]) async throws {
        // Firestore takes at most 500 writes per commit.
        for start in stride(from: 0, to: writes.count, by: 400) {
            let chunk = writes[start..<min(start + 400, writes.count)]
            let body: [String: Any] = ["writes": chunk.map(json)]
            let (data, status) = try await send("POST", "\(base):commit", body: body)
            try check(status, data, "save")
        }
    }

    private func json(_ write: FirestoreWrite) -> [String: Any] {
        switch write {
        case .merge(let path, let fields, let stampsUpdatedAt):
            var object: [String: Any] = [
                "update": ["name": "\(root)/\(path)", "fields": fields.mapValues(\.json)],
                "updateMask": ["fieldPaths": fields.keys.sorted().map(Self.fieldPath)],
            ]
            if stampsUpdatedAt {
                object["updateTransforms"] = [["fieldPath": "updatedAt", "setToServerValue": "REQUEST_TIME"]]
            }
            return object
        case .delete(let path):
            return ["delete": "\(root)/\(path)"]
        }
    }

    /// Field names that aren't plain identifiers must be backquoted in a field path.
    private static func fieldPath(_ name: String) -> String {
        let plain = name.first.map { $0.isLetter || $0 == "_" } == true && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return plain ? name : "`\(name.replacingOccurrences(of: "`", with: "\\`"))`"
    }

    private func send(_ method: String, _ url: String, body: [String: Any]? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: url) else { throw StowError.parse("Bad Firestore URL \(url)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let response = try await http.send(request)
        return (response.data, response.status)
    }

    private func check(_ status: Int, _ data: Data, _ action: String) throws {
        guard !(200..<300).contains(status) else { return }
        let message = FirebaseHTTP.message(from: data)
        if status == 404, message.contains("database") {
            throw StowError.network("Firestore isn't set up in project \(projectId) (Build › Firestore Database › Create database).")
        }
        throw StowError.network("Firestore couldn't \(action) (HTTP \(status)): \(message)")
    }
}

/// Firebase Cloud Messaging (HTTP v1), as the service account.
struct FCMREST: Sendable {
    let projectId: String
    let token: @Sendable () async throws -> String
    let http: FirebaseHTTP

    enum Outcome: Equatable, Sendable {
        case sent
        /// The app was uninstalled or the token is stale; the phone sends a new one when it runs.
        case tokenInvalid
    }

    /// A high-priority data message, so Android wakes the app even in Doze.
    func send(data: [String: String], to token: String) async throws -> Outcome {
        guard let url = URL(string: "https://fcm.googleapis.com/v1/projects/\(projectId)/messages:send") else {
            throw StowError.parse("Bad FCM URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await self.token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let message: [String: Any] = ["message": ["token": token, "data": data, "android": ["priority": "HIGH"]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (body, status) = try await http.send(request)
        if (200..<300).contains(status) { return .sent }
        let text = String(decoding: body, as: UTF8.self)
        if status == 404 || (status == 400 && (text.contains("UNREGISTERED") || text.contains("registration token"))) {
            return .tokenInvalid
        }
        throw StowError.network("Couldn't send the push to the phone (HTTP \(status)): \(FirebaseHTTP.message(from: body))")
    }
}
