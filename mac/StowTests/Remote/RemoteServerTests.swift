import Foundation
import Network
import Testing
@testable import Stow

/// The real server, reachable from this Mac only, without Bonjour.
struct RemoteServerTests {
    /// Sends `request` raw and returns everything the server sent until it closed the connection.
    private func exchange(_ request: Data, port: UInt16) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "RemoteServerTests")
        connection.start(queue: queue)
        connection.send(content: request, completion: .idempotent)
        return try await withCheckedThrowingContinuation { continuation in
            func read(_ received: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    let received = received + (data ?? Data())
                    if isComplete || error != nil {
                        continuation.resume(returning: String(decoding: received, as: UTF8.self))
                    } else {
                        read(received)
                    }
                }
            }
            read(Data())
        }
    }

    @Test func answersOverTCPAndClosesTheConnection() async throws {
        let server = RemoteServer(loopbackOnly: true) { request in
            .json(["path": request.path, "body": String(decoding: request.body, as: UTF8.self)])
        }
        let port = try await server.start(port: nil, serviceName: nil)
        defer { server.stop() }

        let ok = try await exchange(Data("POST /v1/action?x HTTP/1.1\r\nContent-Length: 17\r\n\r\n{\"action\":\"next\"}".utf8), port: port)
        #expect(ok.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(ok.contains("Connection: close\r\n"))
        #expect(ok.hasSuffix(#"{"body":"{\"action\":\"next\"}","path":"/v1/action"}"#))

        let bad = try await exchange(Data("hello\r\n\r\n".utf8), port: port)
        #expect(bad.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        let large = try await exchange(Data("POST /v1/action HTTP/1.1\r\nContent-Length: 100000\r\n\r\n".utf8), port: port)
        #expect(large.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"))
    }

    @Test func aTakenPortFails() async throws {
        let first = RemoteServer(loopbackOnly: true) { _ in .error(.notFound, "") }
        let port = try await first.start(port: nil, serviceName: nil)
        defer { first.stop() }
        let second = RemoteServer(loopbackOnly: true) { _ in .error(.notFound, "") }
        await #expect(throws: (any Error).self) { try await second.start(port: port, serviceName: nil) }
        second.stop()
    }
}
