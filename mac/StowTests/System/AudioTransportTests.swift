import CoreAudio
import Testing
@testable import Stow

struct AudioTransportTests {
    @Test func mapsCoreAudioTransportTypes() {
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeDisplayPort) == .displayPort)
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeHDMI) == .hdmi)
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeUSB) == .usb)
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeAirPlay) == .airPlay)
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeVirtual) == .virtual)
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeAggregate) == .virtual)
        #expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeThunderbolt) == .other)
        #expect(AudioTransport(coreAudio: 0) == .other)
    }
}
