import Foundation

/// Brown (red) noise at a set RMS level: white noise through a leaky integrator, normalized by
/// the integrator's theoretical RMS. Deterministic for a given seed. Not thread-safe: one
/// generator per render thread.
struct BrownNoise {
    /// y[n] = a·y[n−1] + g·w[n], w uniform in [−1, 1] (variance 1/3); corner ≈ 150 Hz at 48 kHz.
    private static let leak = 1 / 1.02
    private static let gain = 0.02 / 1.02
    /// RMS of y: sqrt(g² · (1/3) / (1 − a²)).
    static let unitRMS = (gain * gain / 3 / (1 - leak * leak)).squareRoot()

    private var state: UInt64
    private var last = 0.0

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        state = seed == 0 ? 1 : seed
    }

    /// Linear amplitude for an RMS level in dBFS.
    static func amplitude(dBFS: Double) -> Double {
        pow(10, dBFS / 20)
    }

    /// The next sample with RMS `amplitude`, clipped to [−1, 1].
    mutating func next(amplitude: Double) -> Float {
        last = Self.leak * last + Self.gain * white()
        return Float(min(max(last / Self.unitRMS * amplitude, -1), 1))
    }

    /// Uniform in [−1, 1] (xorshift64*).
    private mutating func white() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let bits = (state &* 0x2545_F491_4F6C_DD1D) >> 11
        return Double(bits) / Double(1 << 53) * 2 - 1
    }
}
