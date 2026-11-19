import Foundation

/// Pure Bluetooth helpers: address formatting, class-of-device decoding and page timeouts.
enum BluetoothAddress {
    /// "40-c1-f6-88-8f-af" / "40C1F6888FAF" → "40:C1:F6:88:8F:AF"; nil unless exactly 12 hex digits.
    static func formatted(_ text: String) -> String? {
        let hex = AudioOutput.normalizedAddress(text)
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start ..< hex.index(start, offsetBy: 2)])
        }.joined(separator: ":")
    }

    /// Whether a class of device (Bluetooth Core spec, Assigned Numbers) describes something that
    /// plays audio: the Audio/Video major class except minors that don't, or the Rendering + Audio
    /// service classes (Audio alone is also set by phones).
    static func isAudio(classOfDevice: UInt32) -> Bool {
        let renderingAndAudio: UInt32 = 1 << 18 | 1 << 21
        if classOfDevice & renderingAndAudio == renderingAndAudio { return true }
        let major = (classOfDevice >> 8) & 0x1F
        let minor = (classOfDevice >> 2) & 0x3F
        let silentMinors: Set<UInt32> = [0x04 /* microphone */, 0x0C /* video camera */, 0x0D /* camcorder */,
                                         0x0E /* video monitor */]
        return major == 0x04 && !silentMinors.contains(minor)
    }

    /// An HCI page timeout (0.625 ms slots, at most 0xFFFF ≈ 41 s) for `timeout`.
    static func pageTimeout(for timeout: Duration) -> UInt16 {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return UInt16(min(max(seconds / 0.000625, 1), Double(UInt16.max)).rounded(.down))
    }
}
