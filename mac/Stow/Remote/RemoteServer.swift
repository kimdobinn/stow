import Foundation
import Network
import os

/// Serves HTTP requests to a handler; `RemoteServer`, or a fake in tests.
protocol RemoteListening: AnyObject, Sendable {
    /// Listens on `port` (nil = any free port), advertising `serviceName` over Bonjour when given.
    /// Returns the port. Throws when it can't listen there.
    func start(port: UInt16?, serviceName: String?) async throws -> UInt16
    /// Stops listening at once; requests already being answered get a moment to finish.
    func stop()
}

/// A minimal HTTP/1.1 server on Network.framework for the phone remote: one request per
/// connection (each answer closes it), at most 64 KB a request, a few connections at a time.
final class RemoteServer: RemoteListening, @unchecked Sendable {
    typealias Handler = @Sendable (RemoteHTTPRequest) async -> RemoteHTTPResponse

    static let serviceType = "_stow-remote._tcp"
    /// A connection that hasn't sent a whole request by then is dropped.
    static let requestTimeout: TimeInterval = 10
    /// Requests being answered when the server stops get this long to finish.
    static let stopGrace: TimeInterval = 3
    static let maxConnections = 16

    private let handler: Handler
    private let loopbackOnly: Bool
    private let queue = DispatchQueue(label: "dev.stow.remote-server")
    /// Touched only on `queue`.
    private var listener: NWListener?
    private var isStopped = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// `loopbackOnly` (tests) accepts connections from this Mac only.
    init(loopbackOnly: Bool = false, handler: @escaping Handler) {
        self.loopbackOnly = loopbackOnly
        self.handler = handler
    }

    func start(port: UInt16?, serviceName: String?) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        let listener = try NWListener(using: parameters, on: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        if let serviceName { listener.service = NWListener.Service(name: serviceName, type: Self.serviceType) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            @Sendable func finish(_ result: Result<UInt16, any Error>) {
                guard !resumed.withLock({ let was = $0; $0 = true; return was }) else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, !isStopped else {
                        listener.cancel()
                        return finish(.failure(CancellationError()))
                    }
                    finish(listener.port.map { .success($0.rawValue) } ?? .failure(StowError.network("No listening port.")))
                case .failed(let error), .waiting(let error) where error == .posix(.EADDRINUSE):
                    listener.cancel()
                    finish(.failure(error))
                case .waiting(let error) where serviceName != nil && !resumed.withLock({ $0 }):
                    // An advertising listener waits here until macOS allows Local Network access,
                    // which nobody may answer before the alarm; the caller listens without Bonjour.
                    listener.cancel()
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CancellationError()))
                default:
                    // Waiting without Bonjour (no network yet): it listens once it can; `stop` cancels it.
                    break
                }
            }
            queue.async { [weak self] in
                guard let self, !isStopped else { return finish(.failure(CancellationError())) }
                self.listener = listener
                listener.start(queue: queue)
            }
        }
    }

    /// A stopped server doesn't start again.
    func stop() {
        queue.async { [self] in
            isStopped = true
            listener?.cancel()
            listener = nil
            queue.asyncAfter(deadline: .now() + Self.stopGrace) { [self] in
                connections.values.forEach { $0.forceCancel() }
                connections = [:]
            }
        }
    }

    // MARK: Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < Self.maxConnections else { return connection.cancel() }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self, weak connection] in
            guard let connection, self?.connections[id] != nil else { return }
            connection.cancel()
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: RemoteHTTPRequest.sizeLimit) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch RemoteHTTPRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { return connection.cancel() }
                receive(on: connection, buffer: buffer)
            case .failure(let status, let message):
                respond(on: connection, .error(status, message))
            case .request(let request):
                let handler = handler
                Task {
                    let response = await handler(request)
                    self.queue.async { self.respond(on: connection, response) }
                }
            }
        }
    }

    private func respond(on connection: NWConnection, _ response: RemoteHTTPResponse) {
        connection.send(content: response.serialized, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
