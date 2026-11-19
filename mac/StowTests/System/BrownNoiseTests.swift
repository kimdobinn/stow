import Foundation
import Testing
@testable import Stow

struct BrownNoiseTests {
    private func rms(levelDBFS: Double, samples: Int = 400_000, seed: UInt64 = 42) -> Double {
        var noise = BrownNoise(seed: seed)
        let amplitude = BrownNoise.amplitude(dBFS: levelDBFS)
        // Skip the integrator's settling time.
        for _ in 0 ..< 1_000 { _ = noise.next(amplitude: amplitude) }
        let sum = (0 ..< samples).reduce(0.0) { total, _ in
            let sample = Double(noise.next(amplitude: amplitude))
            return total + sample * sample
        }
        return (sum / Double(samples)).squareRoot()
    }

    private func dB(_ amplitude: Double) -> Double { 20 * log10(amplitude) }

    @Test func amplitudeFromDBFS() {
        #expect(BrownNoise.amplitude(dBFS: 0) == 1)
        #expect(abs(BrownNoise.amplitude(dBFS: -20) - 0.1) < 1e-12)
        #expect(abs(BrownNoise.amplitude(dBFS: -60) - 0.001) < 1e-12)
        #expect(abs(BrownNoise.amplitude(dBFS: -6.0206) - 0.5) < 1e-4)
    }

    @Test(arguments: [-90.0, -60.0, -40.0, -20.0])
    func measuredLevelMatchesRequested(level: Double) {
        #expect(abs(dB(rms(levelDBFS: level)) - level) < 0.5)
    }

    @Test func zeroAmplitudeIsSilent() {
        var noise = BrownNoise()
        #expect((0 ..< 1_000).allSatisfy { _ in noise.next(amplitude: 0) == 0 })
    }

    @Test func staysWithinFullScale() {
        var noise = BrownNoise(seed: 7)
        #expect((0 ..< 100_000).allSatisfy { _ in abs(noise.next(amplitude: 4)) <= 1 })
    }

    @Test func deterministicPerSeed() {
        var a = BrownNoise(seed: 3), b = BrownNoise(seed: 3), c = BrownNoise(seed: 4)
        let first = (0 ..< 100).map { _ in a.next(amplitude: 0.1) }
        #expect(first == (0 ..< 100).map { _ in b.next(amplitude: 0.1) })
        #expect(first != (0 ..< 100).map { _ in c.next(amplitude: 0.1) })
    }

    @Test func mostEnergyIsLowFrequency() {
        // Brown noise: neighbouring samples are strongly correlated, unlike white noise.
        var noise = BrownNoise(seed: 11)
        let samples = (0 ..< 50_000).map { _ in Double(noise.next(amplitude: 0.1)) }
        let lagged = zip(samples, samples.dropFirst()).reduce(0) { $0 + $1.0 * $1.1 }
        let energy = samples.reduce(0) { $0 + $1 * $1 }
        #expect(lagged / energy > 0.9)
    }
}
