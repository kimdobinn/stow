import SwiftUI

/// The frame and time at the spot on the timeline under the pointer, floating above it.
struct ScrubPreview: View {
    let fraction: Double
    let duration: TimeInterval
    /// The widest the frame gets (it is a quarter of the bar's width, at least 150).
    var maxWidth: CGFloat = 260
    var fontSize: CGFloat = 12
    private let loader = StoryboardLoader.shared

    var body: some View {
        GeometryReader { proxy in
            let barWidth = proxy.size.width
            let width = min(max(barWidth * 0.26, 150), maxWidth)
            let time = fraction * duration
            let image = loader.image(at: time)
            let frameHeight = image.map { width * CGFloat($0.height) / CGFloat(max($0.width, 1)) }
            VStack(spacing: 4) {
                if let image, let frameHeight {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: width, height: frameHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.5), radius: 6)
                }
                Text(AlarmText.playbackTime(time))
                    .font(.system(size: fontSize, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            }
            .frame(width: width)
            .fixedSize()
            .position(x: min(max(fraction * barWidth, width / 2), max(barWidth - width / 2, width / 2)),
                      y: -((frameHeight.map { $0 + 4 } ?? 0) + fontSize + 7) / 2 - 2)
        }
        .allowsHitTesting(false)
    }
}
