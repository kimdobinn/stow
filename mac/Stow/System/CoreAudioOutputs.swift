import AudioToolbox
import CoreAudio
import Foundation

/// CoreAudio output devices and their volume.
struct CoreAudioOutputs: AudioOutputService {
    func outputs() -> [AudioOutput] {
        let defaultID = Self.defaultOutputID()
        return Self.outputDeviceIDs().compactMap { id in
            guard let uid = AudioObject.string(id, AudioObject.address(kAudioDevicePropertyDeviceUID)) else { return nil }
            let name = AudioObject.string(id, AudioObject.address(kAudioObjectPropertyName)) ?? uid
            let transport = AudioObject.get(id, AudioObject.address(kAudioDevicePropertyTransportType), as: UInt32.self)
            return AudioOutput(uid: uid, name: name, transport: AudioTransport(coreAudio: transport ?? 0),
                               isDefault: id == defaultID)
        }
    }

    func volume(deviceUID: String) -> Double? {
        guard let id = Self.deviceID(uid: deviceUID) else { return nil }
        for address in [Self.virtualMainVolume, Self.volumeScalar(element: kAudioObjectPropertyElementMain)] {
            if let value = AudioObject.get(id, address, as: Float32.self) { return Double(value) }
        }
        let channels = Self.stereoChannels(id).compactMap { AudioObject.get(id, Self.volumeScalar(element: $0), as: Float32.self) }
        return channels.isEmpty ? nil : Double(channels.reduce(0, +)) / Double(channels.count)
    }

    /// Sets the device's virtual main volume, else its main volume, else the volume of its stereo
    /// channels, and unmutes it when `volume` > 0. Never touches the system default device.
    func setVolume(_ volume: Double, deviceUID: String) throws {
        guard let id = Self.deviceID(uid: deviceUID) else { throw StowError.audioDeviceNotFound(deviceUID) }
        let scalar = Float32(min(max(volume, 0), 1))
        let mainAddresses = [Self.virtualMainVolume, Self.volumeScalar(element: kAudioObjectPropertyElementMain)]
        let channelAddresses = Self.stereoChannels(id).map { Self.volumeScalar(element: $0) }
        let targets = mainAddresses.first { AudioObject.isSettable(id, $0) }.map { [$0] }
            ?? channelAddresses.filter { AudioObject.isSettable(id, $0) }
        guard !targets.isEmpty else { throw StowError.audio("\(deviceUID) has no volume control.") }
        for address in targets {
            let status = AudioObject.set(id, address, to: scalar)
            guard status == noErr else { throw StowError.audio("Couldn't set the volume of \(deviceUID) (\(status)).") }
        }
        let mute = AudioObject.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        if scalar > 0, AudioObject.get(id, mute, as: UInt32.self) == 1, AudioObject.isSettable(id, mute) {
            _ = AudioObject.set(id, mute, to: UInt32(0))
        }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "dev.stow.audio-device-changes")
            let listener: AudioObjectPropertyListenerBlock = { _, _ in continuation.yield() }
            let addresses = [AudioObject.address(kAudioHardwarePropertyDevices),
                             AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice)]
            for var address in addresses {
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            }
            continuation.onTermination = { _ in
                for var address in addresses {
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
                }
            }
        }
    }

    /// The live device with this UID, if it has output channels.
    static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObject.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown, outputDeviceIDs().contains(id) else { return nil }
        return id
    }

    private static func outputDeviceIDs() -> [AudioDeviceID] {
        AudioObject.array(AudioObjectID(kAudioObjectSystemObject), AudioObject.address(kAudioHardwarePropertyDevices),
                          of: AudioDeviceID.self)
            .filter { id in
                let streams = AudioObject.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
                let alive = AudioObject.get(id, AudioObject.address(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self)
                return alive != 0 && !AudioObject.array(id, streams, of: AudioStreamID.self).isEmpty
            }
    }

    private static func defaultOutputID() -> AudioDeviceID? {
        AudioObject.get(AudioObjectID(kAudioObjectSystemObject),
                        AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice), as: AudioDeviceID.self)
    }

    private static let virtualMainVolume = AudioObject.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                               scope: kAudioObjectPropertyScopeOutput)

    private static func volumeScalar(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObject.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: element)
    }

    private static func stereoChannels(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        let preferred = AudioObject.array(id, AudioObject.address(kAudioDevicePropertyPreferredChannelsForStereo,
                                                                  scope: kAudioObjectPropertyScopeOutput), of: UInt32.self)
        return preferred.count == 2 ? preferred : [1, 2]
    }
}

extension AudioTransport {
    init(coreAudio transportType: UInt32) {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate: self = .virtual
        default: self = .other
        }
    }
}
