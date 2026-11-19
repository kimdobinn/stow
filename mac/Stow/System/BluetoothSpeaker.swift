import IOBluetooth

/// Paired Bluetooth audio devices via IOBluetooth: listing, connection state and connecting.
@MainActor
final class BluetoothSpeaker: SpeakerService {
    /// Connection attempts in flight; IOBluetooth messages them on the main run loop.
    private var pendingConnections: Set<ConnectionAttempt> = []

    /// IOBluetooth's first call sets up a shared coordinator that blocks until the main run loop
    /// answers it (and, the very first time, until the user answers the Bluetooth permission
    /// prompt). Made on the main thread before the app is running, that call never returns, so
    /// it's made once on a background thread and every other call waits for it.
    private static let warmUp = Task.detached(priority: .userInitiated) {
        _ = IOBluetoothDevice.pairedDevices()
    }
    private static var isReady = false

    init() {
        Task { await Self.ready() }
    }

    private static func ready() async {
        guard !isReady else { return }
        await warmUp.value
        isReady = true
    }

    /// Empty until IOBluetooth is ready (see `warmUp`); the Alarm section refreshes every few seconds.
    func pairedAudioDevices() -> [BluetoothAudioDevice] {
        Self.pairedDevices()
            .filter { BluetoothAddress.isAudio(classOfDevice: $0.classOfDevice) }
            .compactMap { device in
                guard let address = device.addressString.flatMap(BluetoothAddress.formatted) else { return nil }
                return BluetoothAudioDevice(address: address, name: device.name ?? address, isConnected: device.isConnected())
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isConnected(address: String) -> Bool {
        Self.device(address: address)?.isConnected() ?? false
    }

    /// Opens a baseband connection (macOS then connects the audio profiles, and the CoreAudio
    /// output appears a few seconds later) and polls until connected, failed or `timeout`.
    func connect(address: String, timeout: Duration) async -> Bool {
        await Self.ready()
        guard let device = Self.device(address: address) else { return false }
        if device.isConnected() { return true }
        let attempt = ConnectionAttempt { [weak self] in self?.pendingConnections.remove($0) }
        pendingConnections.insert(attempt)
        let status = device.openConnection(attempt, withPageTimeout: BluetoothAddress.pageTimeout(for: timeout),
                                           authenticationRequired: false)
        guard status == kIOReturnSuccess else {
            pendingConnections.remove(attempt)
            return false
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !device.isConnected(), !attempt.isFinished, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return device.isConnected()
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let setUp = Task { @MainActor in
                await Self.ready()
                guard !Task.isCancelled else { return }
                let observer = ConnectionObserver { continuation.yield() }
                continuation.onTermination = { _ in
                    Task { @MainActor in observer.invalidate() }
                }
                // Devices may have connected while IOBluetooth was getting ready.
                continuation.yield()
            }
            continuation.onTermination = { _ in setUp.cancel() }
        }
    }

    private static func pairedDevices() -> [IOBluetoothDevice] {
        guard isReady else { return [] }
        return (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    private static func device(address: String) -> IOBluetoothDevice? {
        let wanted = AudioOutput.normalizedAddress(address)
        guard !wanted.isEmpty else { return nil }
        return pairedDevices().first { AudioOutput.normalizedAddress($0.addressString ?? "") == wanted }
    }
}

/// Target of an asynchronous `openConnection`; IOBluetooth messages it (without retaining it)
/// when the attempt ends, at the latest after the page timeout.
@MainActor
private final class ConnectionAttempt: NSObject {
    private(set) var isFinished = false
    private let onFinish: (ConnectionAttempt) -> Void

    init(onFinish: @escaping (ConnectionAttempt) -> Void) {
        self.onFinish = onFinish
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        isFinished = true
        onFinish(self)
    }
}

/// Yields on every Bluetooth connect, and on the disconnect of every device seen connecting
/// (IOBluetooth also reports devices already connected when the observer registers).
@MainActor
private final class ConnectionObserver: NSObject {
    private let onChange: () -> Void
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [IOBluetoothUserNotification] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    func invalidate() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.forEach { $0.unregister() }
        disconnectNotifications = []
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let disconnect = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))) {
            disconnectNotifications.append(disconnect)
        }
        onChange()
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        disconnectNotifications.removeAll { $0 === notification }
        notification.unregister()
        onChange()
    }
}
