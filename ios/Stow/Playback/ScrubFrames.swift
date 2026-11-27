import AVFoundation
import Observation
import UIKit

/// While scrubbing a downloaded video: the frame near the finger (its closest keyframe, which is
/// quick). One is read at a time; while the finger moves, only the latest position is read next.
/// Streams have no frames to show, as on Android.
@MainActor
@Observable
final class ScrubFrames {
    private(set) var image: UIImage?

    @ObservationIgnored private var generator: FrameReader?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var wanted: Double?
    @ObservationIgnored private var reading = false

    func use(_ file: URL?) {
        guard file != self.file else { return }
        self.file = file
        image = nil
        generator = file.map(FrameReader.init)
    }

    func show(_ seconds: Double) {
        guard generator != nil else { return }
        wanted = seconds
        guard !reading else { return }
        reading = true
        Task { await readLatest() }
    }

    private func readLatest() async {
        while let seconds = wanted, let generator {
            wanted = nil
            let frame = await generator.frame(at: seconds)
            if let frame, generator === self.generator { image = frame }
        }
        reading = false
    }
}

/// Reads frames off the main thread (AVAssetImageGenerator may be used from any one thread at a time,
/// and ScrubFrames asks for one frame at a time).
nonisolated private final class FrameReader: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(_ file: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 384, height: 216)
        // The nearest keyframe is close enough and quick to read.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
    }

    func frame(at seconds: Double) async -> UIImage? {
        guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: image)
    }
}
