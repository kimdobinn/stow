import Foundation
import Testing
@testable import Stow

struct RemoteHTTPTests {
    private func parse(_ text: String, limit: Int = RemoteHTTPRequest.sizeLimit) -> RemoteHTTPRequest.Parsed {
        RemoteHTTPRequest.parse(Data(text.utf8), limit: limit)
    }

    private func status(_ parsed: RemoteHTTPRequest.Parsed) -> RemoteHTTPStatus? {
        if case .failure(let status, _) = parsed { status } else { nil }
    }

    @Test func parsesAGetWithoutBody() {
        let parsed = parse("GET /v1/state?x=1 HTTP/1.1\r\nHost: 192.168.0.5:48261\r\nX-Stow-Time: 1700000000000\r\n\r\n")
        #expect(parsed == .request(RemoteHTTPRequest(method: "GET", path: "/v1/state",
                                                     headers: ["host": "192.168.0.5:48261", "x-stow-time": "1700000000000"],
                                                     body: Data())))
    }

    @Test func parsesAPostBodyAndIgnoresWhatFollows() {
        let parsed = parse("POST /v1/action HTTP/1.1\r\ncontent-length: 17\r\nContent-Type: application/json\r\n\r\n{\"action\":\"next\"}GET /")
        guard case .request(let request) = parsed else {
            Issue.record("not parsed: \(parsed)")
            return
        }
        #expect(request.method == "POST")
        #expect(request.header("Content-Type") == "application/json")
        #expect(String(decoding: request.body, as: UTF8.self) == #"{"action":"next"}"#)
    }

    @Test func waitsForTheWholeHeadAndBody() {
        #expect(parse("GET /v1/state HTTP/1.1\r\nHost: x\r\n") == .incomplete)
        #expect(parse("POST /v1/action HTTP/1.1\r\nContent-Length: 17\r\n\r\n{\"action\"") == .incomplete)
    }

    @Test func rejectsMalformedRequests() {
        #expect(status(parse("GET /v1/state\r\n\r\n")) == .badRequest)
        #expect(status(parse("get /v1/state HTTP/1.1\r\n\r\n")) == .badRequest)
        #expect(status(parse("GET http://mac/v1/state HTTP/1.1\r\n\r\n")) == .badRequest)
        #expect(status(parse("GET /v1/state HTTP/2\r\n\r\n")) == .badRequest)
        #expect(status(parse("GET /v1/state HTTP/1.1\r\nNoColon\r\n\r\n")) == .badRequest)
        #expect(status(parse("GET /v1/state HTTP/1.1\r\nA: b\r\n folded\r\n\r\n")) == .badRequest)
        #expect(status(parse("POST /v1/action HTTP/1.1\r\nContent-Length: -1\r\n\r\n")) == .badRequest)
        #expect(status(parse("POST /v1/action HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}")) == .badRequest)
        #expect(status(parse("POST /v1/action HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")) == .badRequest)
        #expect(status(RemoteHTTPRequest.parse(Data([0x47, 0xff, 0x0d, 0x0a, 0x0d, 0x0a]))) == .badRequest)
    }

    @Test func rejectsRequestsOverTheLimit() {
        #expect(status(parse("POST /v1/action HTTP/1.1\r\nContent-Length: 65536\r\n\r\n")) == .payloadTooLarge)
        #expect(status(parse("GET /v1/state HTTP/1.1\r\nX: " + String(repeating: "a", count: 70_000))) == .payloadTooLarge)
        // Exactly at the limit is fine.
        let head = "POST /v1/action HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        #expect(status(parse(head + "0123456789", limit: head.utf8.count + 10)) == nil)
        #expect(status(parse(head + "0123456789", limit: head.utf8.count + 9)) == .payloadTooLarge)
    }

    @Test func serializesJSONResponses() {
        let response = RemoteHTTPResponse.error(.conflict, "Nothing is playing yet.")
        #expect(String(decoding: response.serialized, as: UTF8.self) == """
            HTTP/1.1 409 Conflict\r
            Content-Type: application/json; charset=utf-8\r
            Content-Length: 35\r
            Cache-Control: no-store\r
            Connection: close\r
            \r
            {"error":"Nothing is playing yet."}
            """)
    }
}
