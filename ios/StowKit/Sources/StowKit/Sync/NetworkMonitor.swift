import Foundation
import Network

/// What the phone is connected to, as far as downloads care.
public struct NetworkStatus: Hashable, Sendable {
    public var isConnected: Bool
    /// Cellular or a personal hotspot (NWPath.isExpensive), or Low Data Mode (isConstrained).
    public var isMetered: Bool

    public init(isConnected: Bool, isMetered: Bool) {
        self.isConnected = isConnected
        self.isMetered = isMetered
    }

    public static let wifi = NetworkStatus(isConnected: true, isMetered: false)
    public static let cellular = NetworkStatus(isConnected: true, isMetered: true)
    public static let offline = NetworkStatus(isConnected: false, isMetered: false)

    /// Whether a download may run now.
    public func allowsDownloads(wifiOnly: Bool) -> Bool { isConnected && (!wifiOnly || !isMetered) }
}

/// The network as the download queue sees it.
@MainActor
public protocol NetworkMonitoring: AnyObject {
    var status: NetworkStatus { get }
    /// Called on the main actor whenever `status` changes.
    var onChange: ((NetworkStatus) -> Void)? { get set }
}

/// NWPathMonitor, reporting on the main queue.
@MainActor
public final class PathMonitor: NetworkMonitoring {
    public private(set) var status: NetworkStatus
    public var onChange: ((NetworkStatus) -> Void)?
    private let monitor = NWPathMonitor()

    public init() {
        status = Self.status(of: monitor.currentPath)
        monitor.pathUpdateHandler = { [weak self] path in
            let status = Self.status(of: path)
            MainActor.assumeIsolated {
                guard let self, self.status != status else { return }
                self.status = status
                self.onChange?(status)
            }
        }
        monitor.start(queue: .main)
    }

    deinit { monitor.cancel() }

    nonisolated static func status(of path: NWPath) -> NetworkStatus {
        NetworkStatus(isConnected: path.status == .satisfied, isMetered: path.isExpensive || path.isConstrained)
    }
}

/// A fixed network, for tests and previews.
@MainActor
public final class FixedNetwork: NetworkMonitoring {
    public var status: NetworkStatus { didSet { if status != oldValue { onChange?(status) } } }
    public var onChange: ((NetworkStatus) -> Void)?

    public init(_ status: NetworkStatus = .wifi) { self.status = status }
}
