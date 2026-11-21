import CryptoKit
import Darwin
import Foundation
import SystemConfiguration

/// The paired phone's remote for a running alarm. From prep until the run ends it serves
/// `RemoteAPI` on the local network (port 48261 when free) and advertises it over Bonjour; when
/// the videos start it tells the phones by FCM where to find it, and when the run ends that it
/// is over. Without a pairing key (no phone ever paired) nothing listens.
@MainActor
final class AlarmRemote: AlarmRemoteService {
    static let preferredPort: UInt16 = 48261

    private let loadKey: () -> SymmetricKey?
    private let makeServer: (@escaping RemoteServer.Handler) -> any RemoteListening
    private let addresses: () -> [String]
    let macName: String
    /// Every request and its answer, and each push, for `Stow --remote-demo`.
    var trace: ((String) -> Void)?
    private let nonces = RemoteNonceStore()

    /// The run being served.
    private struct Session {
        let id: UUID
        weak var run: (any AlarmRunControl)?
        let api: RemoteAPI
        let server: any RemoteListening
        var port: UInt16?
        var pushedPlaying = false
    }
    private var session: Session?

    init(loadKey: @escaping () -> SymmetricKey?,
         makeServer: @escaping (@escaping RemoteServer.Handler) -> any RemoteListening = { RemoteServer(handler: $0) },
         addresses: @escaping () -> [String] = LocalAddresses.ipv4, macName: String = AlarmRemote.computerName) {
        self.loadKey = loadKey
        self.makeServer = makeServer
        self.addresses = addresses
        self.macName = macName
    }

    /// Reads the pairing key file at each run, so a phone paired meanwhile works.
    convenience init(pairingKeyFile: URL) {
        self.init(loadKey: { PairingKey.load(at: pairingKeyFile)?.key })
    }

    func alarmPhaseChanged(_ phase: AlarmPhase, run: any AlarmRunControl) {
        switch phase {
        case .idle:
            end()
        case .preparing, .alarmSound:
            begin(run)
        case .starting, .playing:
            begin(run)
            pushPlayingIfReady()
        }
    }

    private func begin(_ run: any AlarmRunControl) {
        guard session == nil, let key = loadKey() else { return }
        let id = UUID()
        let api = RemoteAPI(run: run, key: key, macName: macName, nonces: nonces,
                            isCurrent: { [weak self] in self?.session?.id == id })
        api.trace = trace
        let server = makeServer { request in await api.handle(request) }
        let session = Session(id: id, run: run, api: api, server: server)
        self.session = session
        Task { await listen(session) }
    }

    /// The preferred port, else any free one (the push and Bonjour carry it). Without Bonjour as a
    /// last resort: macOS holds an advertising listener back until Local Network access is allowed,
    /// and the push still finds a plain one.
    private func listen(_ started: Session) async {
        let tries: [(port: UInt16?, name: String?)] = [(Self.preferredPort, macName), (nil, macName), (Self.preferredPort, nil), (nil, nil)]
        var listening: (port: UInt16, advertised: Bool)?
        for attempt in tries where listening == nil && session?.id == started.id {
            if let port = try? await started.server.start(port: attempt.port, serviceName: attempt.name) {
                listening = (port, attempt.name != nil)
            }
        }
        guard session?.id == started.id else { return started.server.stop() }
        guard let listening else {
            started.run?.log(.warning, "Phone remote: couldn't listen on the network.")
            session = nil
            return started.server.stop()
        }
        session?.port = listening.port
        started.run?.log(.info, "Phone remote: listening on port \(listening.port)"
            + (listening.advertised ? "." : " (not over Bonjour: allow Stow under Privacy & Security › Local Network)."))
        pushPlayingIfReady()
    }

    /// Advertises for a few seconds when a phone is paired, so macOS 15+ asks for Local Network
    /// access while someone is at the Mac rather than first at alarm time. Once answered, it asks no more.
    func askForLocalNetworkAccess() {
        guard loadKey() != nil else { return }
        let server = makeServer { _ in .error(.notFound, "No alarm is running.") }
        let name = macName
        Task {
            _ = try? await server.start(port: nil, serviceName: name)
            try? await Task.sleep(for: .seconds(5))
            server.stop()
        }
    }

    /// Tells the phones once per run, when the videos start and the server is listening.
    private func pushPlayingIfReady() {
        guard let current = session, let port = current.port, !current.pushedPlaying, let run = current.run else { return }
        switch run.phase {
        case .starting, .playing: break
        case .idle, .preparing, .alarmSound: return
        }
        session?.pushedPlaying = true
        push(["type": "alarm", "state": "playing", "port": String(port),
              "hosts": addresses().joined(separator: ","), "macName": macName], via: run)
    }

    private func end() {
        guard let ended = session else { return }
        session = nil
        ended.server.stop()
        if let run = ended.run {
            if ended.pushedPlaying { push(["type": "alarm", "state": "ended"], via: run) }
            if ended.port != nil { run.log(.info, "Phone remote: stopped.") }
        }
    }

    private func push(_ data: [String: String], via run: any AlarmRunControl) {
        trace?("push \(data.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        run.pushToPhones(data)
    }

    /// The Mac's name as Sharing settings show it ("Kim's Mac mini").
    nonisolated static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }
}

/// The Mac's IPv4 addresses the phone might reach it on.
enum LocalAddresses {
    /// Non-loopback IPv4 addresses of interfaces that are up, most likely LAN first.
    static func ipv4() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(interface: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
        }
        return ordered(found)
    }

    /// Private addresses on Ethernet/Wi-Fi (en*) first, then other private ones (VPNs, bridges),
    /// then the rest, link-local (169.254.x) last; ties keep the system's order.
    static func ordered(_ addresses: [(interface: String, address: String)]) -> [String] {
        func rank(_ entry: (interface: String, address: String)) -> Int {
            let octets = entry.address.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { return 4 }
            let isPrivate = octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
            if octets[0] == 169 && octets[1] == 254 { return 3 }
            if isPrivate { return entry.interface.hasPrefix("en") ? 0 : 1 }
            return 2
        }
        var seen = Set<String>()
        return addresses.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element.address)
            .filter { seen.insert($0).inserted }
    }
}
