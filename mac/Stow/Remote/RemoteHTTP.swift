import Foundation

/// The HTTP statuses the phone remote answers with.
enum RemoteHTTPStatus: Int, Equatable, Sendable {
    case ok = 200
    case badRequest = 400
    case unauthorized = 401
    case notFound = 404
    case methodNotAllowed = 405
    case conflict = 409
    case payloadTooLarge = 413

    var reason: String {
        switch self {
        case .ok: "OK"
        case .badRequest: "Bad Request"
        case .unauthorized: "Unauthorized"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .conflict: "Conflict"
        case .payloadTooLarge: "Payload Too Large"
        }
    }
}

/// One HTTP/1.1 request. The remote takes one request per connection, with its body sized by
/// Content-Length (no chunked bodies).
struct RemoteHTTPRequest: Equatable, Sendable {
    static let sizeLimit = 64 * 1024

    var method: String
    /// The target without its query string.
    var path: String
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    enum Parsed: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        case request(RemoteHTTPRequest)
        case failure(RemoteHTTPStatus, String)
    }

    private static let headEnd = Data("\r\n\r\n".utf8)

    /// Parses the bytes received so far. Anything after the body is ignored.
    static func parse(_ data: Data, limit: Int = sizeLimit) -> Parsed {
        guard let end = data.range(of: headEnd) else {
            return data.count > limit ? .failure(.payloadTooLarge, "The request is larger than \(limit) bytes.") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .failure(.badRequest, "The request head isn't UTF-8.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .failure(.badRequest, "Malformed request line.")
        }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        guard !method.isEmpty, method.allSatisfy({ ("A"..."Z").contains($0) }) else {
            return .failure(.badRequest, "Malformed method.")
        }
        guard target.hasPrefix("/") else { return .failure(.badRequest, "The target must be a path.") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line.first != " ", line.first != "\t" else {
                return .failure(.badRequest, "Malformed header line.")
            }
            let name = line[..<colon].lowercased()
            guard !name.contains(where: \.isWhitespace) else { return .failure(.badRequest, "Malformed header name.") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let previous = headers[name] {
                guard name != "content-length" || previous == value else {
                    return .failure(.badRequest, "Conflicting Content-Length headers.")
                }
                headers[name] = name == "content-length" ? value : previous + ", " + value
            } else {
                headers[name] = value
            }
        }
        if headers["transfer-encoding"] != nil {
            return .failure(.badRequest, "Chunked bodies aren't supported; send Content-Length.")
        }

        let bodyStart = end.upperBound
        var length = 0
        if let text = headers["content-length"] {
            guard !text.isEmpty, text.count <= 9, text.allSatisfy(\.isASCIIDigit), let value = Int(text) else {
                return .failure(.badRequest, "Malformed Content-Length.")
            }
            length = value
        }
        guard bodyStart - data.startIndex + length <= limit else {
            return .failure(.payloadTooLarge, "The request is larger than \(limit) bytes.")
        }
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return .request(RemoteHTTPRequest(method: method, path: path, headers: headers,
                                          body: Data(data[bodyStart..<bodyStart + length])))
    }
}

/// A response; the connection closes after it.
struct RemoteHTTPResponse: Equatable, Sendable {
    var status: RemoteHTTPStatus
    /// JSON.
    var body: Data

    static func json(_ value: some Encodable, status: RemoteHTTPStatus = .ok) -> RemoteHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return RemoteHTTPResponse(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ status: RemoteHTTPStatus, _ message: String) -> RemoteHTTPResponse {
        json(["error": message], status: status)
    }

    var serialized: Data {
        var head = "HTTP/1.1 \(status.rawValue) \(status.reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
