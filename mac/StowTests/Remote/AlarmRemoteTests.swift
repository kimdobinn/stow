import Foundation
import Synchronization
import Testing
@testable import Stow

/// Records starts and stops instead of listening; `busyPorts` fail like a port in use, and with
/// `bonjourBlocked` advertising fails like Local Network access not yet allowed.
final class FakeRemoteServer: RemoteListening {
    let handler: RemoteServer.Handler
    let busyPorts: Set<UInt16>
    let bonjourBlocked: Bool
    let starts = Mutex<[(port: UInt16?, name: String?)]>([])
    let stops = Mutex(0)

    init(handler: @escaping RemoteServer.Handler, busyPorts: Set<UInt16> = [], bonjourBlocked: Bool = false) {
        self.handler = handler
        self.busyPorts = busyPorts
        self.bonjourBlocked = bonjourBlocked
    }

    func start(port: UInt16?, serviceName: String?) async throws -> UInt16 {
        starts.withLock { $0.append((port, serviceName)) }
        if let port, busyPorts.contains(port) { throw StowError.network("Address already in use") }
        if bonjourBlocked, serviceName != nil { throw StowError.network("PolicyDenied") }
        return port ?? 50_000
    }

    func stop() { stops.withLock { $0 += 1 } }
}

@MainActor
struct AlarmRemoteTests {
    final class Servers {
        var made: [FakeRemoteServer] = []
    }

    let servers = Servers()
    let run = FakeRunControl(AlarmRunStatus(phase: .preparing(scheduledFor: .now), playlist: [], nowPlaying: nil,
                                            outputName: nil, volume: nil))

    private func makeRemote(key: Bool = true, busyPorts: Set<UInt16> = [], bonjourBlocked: Bool = false) -> AlarmRemote {
        let servers = servers
        return AlarmRemote(loadKey: { key ? remoteTestKey : nil },
                           makeServer: { handler in
                               let server = FakeRemoteServer(handler: handler, busyPorts: busyPorts, bonjourBlocked: bonjourBlocked)
                               servers.made.append(server)
                               return server
                           },
                           addresses: { ["192.168.0.5", "10.0.0.3"] }, macName: "Kim's Mac mini")
    }

    private func change(_ remote: AlarmRemote, to phase: AlarmPhase) async {
        run.status.phase = phase
        remote.alarmPhaseChanged(phase, run: run)
        // Lets the server start finish.
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func listensForTheWholeRunAndTellsThePhones() async throws {
        let remote = makeRemote()
        await change(remote, to: .preparing(scheduledFor: .now))
        await change(remote, to: .preparing(scheduledFor: .now))
        let server = try #require(servers.made.first)
        #expect(servers.made.count == 1)
        #expect(server.starts.withLock { $0.map(\.port) } == [48261])
        #expect(server.starts.withLock { $0.map(\.name) } == ["Kim's Mac mini"])
        #expect(run.pushes.isEmpty)

        await change(remote, to: .starting(output: "JBL Go 3"))
        await change(remote, to: .playing(index: 0, count: 1, video: video("a")))
        #expect(run.pushes == [["type": "alarm", "state": "playing", "port": "48261", "hosts": "192.168.0.5,10.0.0.3",
                                "macName": "Kim's Mac mini"]])

        await change(remote, to: .idle)
        #expect(server.stops.withLock { $0 } == 1)
        #expect(run.pushes.last == ["type": "alarm", "state": "ended"])
        #expect(run.logs == ["Phone remote: listening on port 48261.", "Phone remote: stopped."])

        // The next run gets a new server.
        await change(remote, to: .preparing(scheduledFor: .now))
        #expect(servers.made.count == 2)
    }

    @Test func handsRequestsToTheRun() async throws {
        let remote = makeRemote()
        await change(remote, to: .preparing(scheduledFor: .now))
        let server = try #require(servers.made.first)
        let response = await server.handler(signedRequest(at: .now))
        #expect(response.status == .ok)
        let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(json["phase"] as? String == "preparing")
        #expect(json["macName"] as? String == "Kim's Mac mini")
    }

    @Test func usesAnyPortWhenThePreferredOneIsTaken() async throws {
        let remote = makeRemote(busyPorts: [48261])
        await change(remote, to: .preparing(scheduledFor: .now))
        await change(remote, to: .starting(output: nil))
        let server = try #require(servers.made.first)
        #expect(server.starts.withLock { $0.map(\.port) } == [48261, nil])
        #expect(run.pushes.first?["port"] == "50000")
    }

    @Test func listensWithoutBonjourWhenAdvertisingIsHeldBack() async throws {
        let remote = makeRemote(bonjourBlocked: true)
        await change(remote, to: .preparing(scheduledFor: .now))
        await change(remote, to: .starting(output: nil))
        let server = try #require(servers.made.first)
        #expect(server.starts.withLock { $0.map(\.port) } == [48261, nil, 48261])
        #expect(server.starts.withLock { $0.map(\.name) } == ["Kim's Mac mini", "Kim's Mac mini", nil])
        #expect(run.pushes.first?["port"] == "48261")
        #expect(run.logs.first?.hasPrefix("Phone remote: listening on port 48261 (not over Bonjour") == true)
    }

    @Test func aRequestFromAnEndedRunCantActOnTheNext() async throws {
        let remote = makeRemote()
        run.status = playingStatus()
        await change(remote, to: .playing(index: 0, count: 2, video: video("a")))
        let first = try #require(servers.made.first)
        let stop = signedRequest("POST", "/v1/action", body: #"{"action":"stop"}"#, at: .now)
        #expect(await first.handler(stop).status == .ok)
        await change(remote, to: .idle)
        run.status = playingStatus()
        await change(remote, to: .playing(index: 0, count: 2, video: video("a")))
        let second = try #require(servers.made.last)
        #expect(servers.made.count == 2)

        // Replayed into the next run: its nonce was already used.
        #expect(await second.handler(stop).status == .unauthorized)
        // Still in flight on the old server: the run it was for is over.
        let late = await first.handler(signedRequest("POST", "/v1/action", body: #"{"action":"stop"}"#, at: .now))
        #expect(late.status == .conflict)
        #expect(run.stops == 1)
    }

    @Test func asksForLocalNetworkAccessOnlyOncePaired() async throws {
        makeRemote(key: false).askForLocalNetworkAccess()
        #expect(servers.made.isEmpty)
        makeRemote().askForLocalNetworkAccess()
        try? await Task.sleep(for: .milliseconds(50))
        let server = try #require(servers.made.first)
        #expect(server.starts.withLock { $0.map(\.name) } == ["Kim's Mac mini"])
    }

    @Test func pushesWhenTheServerIsReadyAfterTheVideosStarted() async throws {
        let remote = makeRemote()
        run.status.phase = .starting(output: nil)
        remote.alarmPhaseChanged(.preparing(scheduledFor: .now), run: run)
        remote.alarmPhaseChanged(.starting(output: nil), run: run)
        #expect(run.pushes.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(run.pushes.map { $0["state"] } == ["playing"])
    }

    @Test func aRunThatNeverPlayedEndsQuietly() async throws {
        let remote = makeRemote()
        await change(remote, to: .preparing(scheduledFor: .now))
        await change(remote, to: .alarmSound(reason: "offline"))
        await change(remote, to: .idle)
        #expect(servers.made.first?.stops.withLock { $0 } == 1)
        #expect(run.pushes.isEmpty)
    }

    @Test func nothingListensWithoutAPairingKey() async {
        let remote = makeRemote(key: false)
        await change(remote, to: .preparing(scheduledFor: .now))
        await change(remote, to: .playing(index: 0, count: 1, video: video("a")))
        await change(remote, to: .idle)
        #expect(servers.made.isEmpty)
        #expect(run.pushes.isEmpty)
    }

    @Test func ordersAddressesLANFirst() {
        #expect(LocalAddresses.ordered([("utun4", "10.8.0.2"), ("en1", "169.254.3.4"), ("bridge0", "203.0.113.9"),
                                        ("en0", "192.168.0.5"), ("en0", "192.168.0.5"), ("en5", "172.20.1.2")])
                == ["192.168.0.5", "172.20.1.2", "10.8.0.2", "203.0.113.9", "169.254.3.4"])
    }
}
