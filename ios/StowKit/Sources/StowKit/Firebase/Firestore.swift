import Foundation

/// One write in a commit (all writes of a commit apply together or not at all).
public struct FirestoreWrite: Sendable {
    public enum Mask: Sendable {
        /// Replaces the whole document (a Firestore SDK `set`).
        case replace
        /// Changes only these fields, plus the server timestamps (`set(merge)` or `update`).
        case fields
    }

    public enum Precondition: Sendable {
        case none
        /// Like the SDK's `update`: fails when the document doesn't exist.
        case exists
        case missing
    }

    public var path: String
    public var fields: [String: FirestoreValue]
    public var mask: Mask
    /// Fields set to the server's time of the commit.
    public var serverTimestamps: [String]
    public var precondition: Precondition

    public init(path: String, fields: [String: FirestoreValue], mask: Mask = .fields,
                serverTimestamps: [String] = [], precondition: Precondition = .none) {
        self.path = path
        self.fields = fields
        self.mask = mask
        self.serverTimestamps = serverTimestamps
        self.precondition = precondition
    }

    /// The SDK's `set`.
    public static func set(_ path: String, _ fields: [String: FirestoreValue], serverTimestamps: [String] = []) -> FirestoreWrite {
        FirestoreWrite(path: path, fields: fields, mask: .replace, serverTimestamps: serverTimestamps)
    }

    /// The SDK's `set(…, merge)`.
    public static func merge(_ path: String, _ fields: [String: FirestoreValue], serverTimestamps: [String] = []) -> FirestoreWrite {
        FirestoreWrite(path: path, fields: fields, mask: .fields, serverTimestamps: serverTimestamps)
    }

    /// The SDK's `update`.
    public static func update(_ path: String, _ fields: [String: FirestoreValue], serverTimestamps: [String] = []) -> FirestoreWrite {
        FirestoreWrite(path: path, fields: fields, mask: .fields, serverTimestamps: serverTimestamps, precondition: .exists)
    }
}

/// What a commit returned: the server's values of each write's timestamps, in order.
public struct FirestoreCommitResult: Sendable {
    public var commitTime: Date?
    /// Per write, the server timestamps in the order they were asked for.
    public var serverTimes: [[Date]]
}

/// Firestore's REST API (v1) for the project's (default) database, as the signed-in Firebase user.
/// The security rules apply: a refused read or write throws `.notPaired`.
public struct FirestoreClient: Sendable {
    public let projectId: String
    let auth: FirebaseAuth
    let http: HTTPClient

    public init(projectId: String, auth: FirebaseAuth, session: URLSession) {
        self.projectId = projectId
        self.auth = auth
        self.http = HTTPClient(session: session)
    }

    var root: String { "projects/\(projectId)/databases/(default)/documents" }
    var base: String { "https://firestore.googleapis.com/v1/\(root)" }

    /// nil when the document doesn't exist.
    public func get(_ path: String, transaction: String? = nil) async throws -> FirestoreDocument? {
        var query: [(String, String)] = []
        if let transaction { query.append(("transaction", transaction)) }
        let (data, status) = try await send("GET", "\(base)/\(path)", query: query)
        if status == 404 { return nil }
        try check(status, data, "read \(path)")
        return FirestoreDocument(json: try JSONSerialization.jsonObject(with: data))
    }

    /// Every document of a top-level collection, following the pages.
    public func list(_ collection: String, pageSize: Int = 300) async throws -> [FirestoreDocument] {
        var documents: [FirestoreDocument] = []
        var pageToken: String?
        repeat {
            var query = [("pageSize", String(pageSize))]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let (data, status) = try await send("GET", "\(base)/\(collection)", query: query)
            try check(status, data, "list \(collection)")
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            documents += (object?["documents"] as? [Any] ?? []).compactMap(FirestoreDocument.init(json:))
            pageToken = (object?["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while pageToken != nil
        return documents
    }

    /// Documents of `collection` whose `updatedAt` is after `after` (all when nil), oldest change
    /// first, following on past `limit`. Every Stow write stamps `updatedAt` with the commit time,
    /// so this sees each change once; it can't see deletions (a full `list` does).
    public func changed(_ collection: String, after: String?, limit: Int = 300) async throws -> [FirestoreDocument] {
        var documents: [FirestoreDocument] = []
        var cursor = after
        while true {
            var query: [String: Any] = [
                "from": [["collectionId": collection]],
                "orderBy": [["field": ["fieldPath": "updatedAt"], "direction": "ASCENDING"]],
                "limit": limit,
            ]
            if let cursor {
                query["where"] = ["fieldFilter": ["field": ["fieldPath": "updatedAt"], "op": "GREATER_THAN",
                                                  "value": FirestoreValue.timestamp(cursor).json]]
            }
            let (data, status) = try await send("POST", "\(base):runQuery", body: ["structuredQuery": query])
            try check(status, data, "query \(collection)")
            let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            let page = results.compactMap { $0["document"] }.compactMap(FirestoreDocument.init(json:))
            documents += page
            guard page.count >= limit, let last = page.last?["updatedAt"]?.timestamp, last != cursor else { return documents }
            cursor = last
        }
    }

    /// PATCH: sets `fields` (all of them when `mask` is nil, which replaces the document),
    /// creating the document when it doesn't exist.
    @discardableResult
    public func patch(_ path: String, _ fields: [String: FirestoreValue], mask: [String]? = nil) async throws -> FirestoreDocument? {
        let query = (mask ?? []).map { ("updateMask.fieldPaths", Self.fieldPath($0)) }
        let body: [String: Any] = ["fields": fields.mapValues(\.json)]
        let (data, status) = try await send("PATCH", "\(base)/\(path)", query: query, body: body)
        try check(status, data, "save \(path)")
        return FirestoreDocument(json: try JSONSerialization.jsonObject(with: data))
    }

    @discardableResult
    public func commit(_ writes: [FirestoreWrite], transaction: String? = nil) async throws -> FirestoreCommitResult {
        var body: [String: Any] = ["writes": writes.map(json)]
        if let transaction { body["transaction"] = transaction }
        let (data, status) = try await send("POST", "\(base):commit", body: body)
        try check(status, data, "save")
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let results = object["writeResults"] as? [[String: Any]] ?? []
        let times = results.map { result in
            (result["transformResults"] as? [Any] ?? []).compactMap { FirestoreValue(json: $0).date }
        }
        return FirestoreCommitResult(commitTime: (object["commitTime"] as? String).flatMap(FirestoreTime.date(from:)), serverTimes: times)
    }

    /// Runs `body` in a read-write transaction: reads in it see one snapshot, and the writes it
    /// returns apply only if nothing it read changed meanwhile (else it runs again, up to 5 times).
    public func runTransaction(_ body: (_ transaction: String) async throws -> [FirestoreWrite]) async throws {
        var attempt = 0
        while true {
            attempt += 1
            let (data, status) = try await send("POST", "\(base):beginTransaction", body: ["options": ["readWrite": [String: Any]()]])
            try check(status, data, "start a transaction")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let transaction = object["transaction"] as? String else {
                throw StowError.server("Firestore didn't start the transaction")
            }
            do {
                let writes = try await body(transaction)
                try await commit(writes, transaction: transaction)
                return
            } catch let error as FirestoreConflict where attempt < 5 {
                _ = error
                try await Task.sleep(for: .milliseconds(200 * attempt))
            } catch {
                _ = try? await send("POST", "\(base):rollback", body: ["transaction": transaction])
                throw error
            }
        }
    }

    // Requests

    func json(_ write: FirestoreWrite) -> [String: Any] {
        var object: [String: Any] = ["update": ["name": "\(root)/\(write.path)", "fields": write.fields.mapValues(\.json)]]
        if write.mask == .fields {
            object["updateMask"] = ["fieldPaths": write.fields.keys.sorted().map(Self.fieldPath)]
        }
        if !write.serverTimestamps.isEmpty {
            object["updateTransforms"] = write.serverTimestamps.map { ["fieldPath": Self.fieldPath($0), "setToServerValue": "REQUEST_TIME"] }
        }
        switch write.precondition {
        case .none: break
        case .exists: object["currentDocument"] = ["exists": true]
        case .missing: object["currentDocument"] = ["exists": false]
        }
        return object
    }

    /// Field names that aren't plain identifiers must be backquoted in a field path.
    static func fieldPath(_ name: String) -> String {
        let plain = name.first.map { $0.isLetter || $0 == "_" } == true && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        return plain ? name : "`\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`"
    }

    private func send(_ method: String, _ url: String, query: [(String, String)] = [], body: [String: Any]? = nil) async throws -> (Data, Int) {
        let queryString = query.map { "\(FirebaseAuth.escape($0.0))=\(FirebaseAuth.escape($0.1))" }.joined(separator: "&")
        guard let url = URL(string: queryString.isEmpty ? url : "\(url)?\(queryString)") else {
            throw StowError.parse("Bad Firestore URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.setValue("Bearer \(try await auth.idToken())", forHTTPHeaderField: "Authorization")
        var response = try await http.send(request)
        if response.status == 401 {
            // The ID token ran out early or was revoked: renew once and try again.
            request.setValue("Bearer \(try await auth.idToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            response = try await http.send(request)
        }
        return (response.data, response.status)
    }

    private func check(_ status: Int, _ data: Data, _ action: String) throws {
        guard !(200..<300).contains(status) else { return }
        let googleStatus = HTTPClient.status(from: data)
        if status == 403 || googleStatus == "PERMISSION_DENIED" { throw StowError.notPaired }
        if googleStatus == "ABORTED" { throw FirestoreConflict() }
        let message = HTTPClient.message(from: data)
        throw StowError.server("Firestore couldn't \(action) (HTTP \(status)): \(message)")
    }
}

/// A transaction lost to a concurrent change; it is run again.
struct FirestoreConflict: Error {}
