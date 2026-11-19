import AVFoundation
import Synchronization

/// A near-silent signal on one output device (AVAudioEngine whose output unit is bound to that
/// device, not the system default) so a Bluetooth speaker doesn't power itself off.
/// The signal is brown noise at `levelDBFS` RMS.
@MainActor
final class KeepAlive: KeepAliveService {
    private(set) var isRunning = false
    private(set) var deviceUID: String?
    private var levelDBFS = SpeakerSettings.default.keepAliveLevel
    private var engine: AVAudioEngine?
    private var signal: NoiseSignal?
    private var configurationObserver: (any NSObjectProtocol)?
    private var deviceWatch: Task<Void, Never>?

    func start(deviceUID: String, levelDBFS: Double) throws {
        let range = SpeakerSettings.keepAliveLevelRange
        self.levelDBFS = min(max(levelDBFS, range.lowerBound), range.upperBound)
        if isRunning, deviceUID == self.deviceUID, let signal {
            signal.setLevel(dBFS: self.levelDBFS)
            return
        }
        try run(on: deviceUID)
    }

    func stop() {
        tearDownEngine()
        deviceWatch?.cancel()
        deviceWatch = nil
        isRunning = false
        deviceUID = nil
    }

    func test(deviceUID: String, levelDBFS: Double, duration: Duration) async throws {
        let previous = isRunning ? self.deviceUID.map { (uid: $0, level: self.levelDBFS) } : nil
        defer {
            if let previous {
                try? start(deviceUID: previous.uid, levelDBFS: previous.level)
            } else {
                stop()
            }
        }
        try start(deviceUID: deviceUID, levelDBFS: levelDBFS)
        try? await Task.sleep(for: duration)
    }

    /// (Re)builds the engine on `uid`; leaves everything stopped when that fails.
    private func run(on uid: String) throws {
        tearDownEngine()
        do {
            guard let id = CoreAudioOutputs.deviceID(uid: uid) else { throw StowError.audioDeviceNotFound(uid) }
            let signal = NoiseSignal(levelDBFS: levelDBFS)
            let engine = try Self.makeEngine(deviceID: id, signal: signal)
            self.engine = engine
            self.signal = signal
        } catch {
            stop()
            throw error
        }
        deviceUID = uid
        isRunning = true
        // The engine stops itself when the device's format changes or it goes away.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
        if deviceWatch == nil {
            deviceWatch = Task { [weak self] in
                for await _ in CoreAudioOutputs().changes() {
                    guard let self, let uid = self.deviceUID else { return }
                    if CoreAudioOutputs.deviceID(uid: uid) == nil { self.stop() }
                }
            }
        }
    }

    private func restart() {
        guard isRunning, let deviceUID else { return }
        try? run(on: deviceUID)
    }

    private func tearDownEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine = nil
        signal = nil
    }

    /// The device must be set on the output unit before anything touches the mixer, which
    /// connects itself to the output in the output's current format.
    private nonisolated static func makeEngine(deviceID: AudioDeviceID, signal: NoiseSignal) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { throw StowError.audio("The audio engine has no output unit.") }
        var id = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw StowError.audio("Couldn't bind the keep-alive to the speaker (\(status)).") }

        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate > 0 ? sampleRate : 48_000, channels: 1)
        else { throw StowError.audio("Unsupported output format.") }
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            signal.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw StowError.audio("Couldn't start the keep-alive: \(error.localizedDescription)")
        }
        return engine
    }
}

/// Shared between the main actor (level) and the render thread (noise state).
private final class NoiseSignal: @unchecked Sendable {
    private let amplitudeBits: Atomic<UInt64>
    /// Touched only on the render thread.
    private var noise = BrownNoise()

    init(levelDBFS: Double) {
        amplitudeBits = Atomic(BrownNoise.amplitude(dBFS: levelDBFS).bitPattern)
    }

    func setLevel(dBFS: Double) {
        amplitudeBits.store(BrownNoise.amplitude(dBFS: dBFS).bitPattern, ordering: .relaxed)
    }

    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let amplitude = Double(bitPattern: amplitudeBits.load(ordering: .relaxed))
        for frame in 0 ..< frames {
            let sample = noise.next(amplitude: amplitude)
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
    }
}
