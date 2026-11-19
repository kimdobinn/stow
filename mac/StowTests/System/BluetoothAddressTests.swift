import Testing
@testable import Stow

struct BluetoothAddressTests {
    @Test(arguments: ["40-c1-f6-88-8f-af", "40:C1:F6:88:8F:AF", "40c1f6888faf", " 40-C1-F6-88-8F-AF "])
    func formatsAnyCommonForm(text: String) {
        #expect(BluetoothAddress.formatted(text) == "40:C1:F6:88:8F:AF")
    }

    @Test(arguments: ["", "40:C1:F6:88:8F", "40:C1:F6:88:8F:AF:00", "JBL Go 3"])
    func rejectsWrongLength(text: String) {
        #expect(BluetoothAddress.formatted(text) == nil)
    }

    @Test func audioClassesOfDevice() {
        #expect(BluetoothAddress.isAudio(classOfDevice: 0x240414)) // loudspeaker (JBL-style)
        #expect(BluetoothAddress.isAudio(classOfDevice: 0x240418)) // headphones
        #expect(BluetoothAddress.isAudio(classOfDevice: 0x200404)) // wearable headset
        #expect(BluetoothAddress.isAudio(classOfDevice: 0x00043C)) // video display and loudspeaker
        #expect(BluetoothAddress.isAudio(classOfDevice: 0x040100 | 1 << 21)) // computer advertising rendering + audio
    }

    @Test func nonAudioClassesOfDevice() {
        #expect(!BluetoothAddress.isAudio(classOfDevice: 0x7A020C)) // smartphone (Audio service bit, no Rendering)
        #expect(!BluetoothAddress.isAudio(classOfDevice: 0x002540)) // keyboard
        #expect(!BluetoothAddress.isAudio(classOfDevice: 0x002580)) // mouse
        #expect(!BluetoothAddress.isAudio(classOfDevice: 0x000410)) // microphone
        #expect(!BluetoothAddress.isAudio(classOfDevice: 0x000438)) // video monitor
        #expect(!BluetoothAddress.isAudio(classOfDevice: 0))
    }

    @Test func pageTimeoutInSlots() {
        #expect(BluetoothAddress.pageTimeout(for: .seconds(5)) == 8_000)
        #expect(BluetoothAddress.pageTimeout(for: .milliseconds(1_250)) == 2_000)
        #expect(BluetoothAddress.pageTimeout(for: .seconds(60)) == UInt16.max)
        #expect(BluetoothAddress.pageTimeout(for: .zero) == 1)
    }
}
