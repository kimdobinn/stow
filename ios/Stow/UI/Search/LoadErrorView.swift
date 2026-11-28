import StowKit
import SwiftUI

/// Couldn't reach YouTube: what failed, yt-dlp's reason, and a way to try again.
struct LoadErrorView: View {
    let title: String
    let message: String
    let retry: () -> Void
    @Environment(\.stowColors) private var colors

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(colors.secondaryText)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.text)
            Text(message)
                .font(.footnote)
                .foregroundStyle(colors.secondaryText)
                .lineLimit(3)
            Button("Try again", action: retry)
                .font(.body.weight(.medium))
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }
}

/// A spinner with a short line, for something that takes a few seconds.
struct LoadingRow: View {
    var text: String?
    @Environment(\.stowColors) private var colors

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(colors.secondaryText)
            if let text {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(colors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.vertical, text == nil ? 40 : 12)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text ?? "Loading")
    }
}

/// A grey stand-in for a video still on its way, like YouTube's while a list loads: the shape of
/// a row (or a card) pulsing gently, so the real ones fade in over something instead of jumping
/// into an empty screen. Still with Reduce Motion. `label` makes it the one VoiceOver reads.
struct PlaceholderVideo: View {
    var card = false
    var label: String?
    @Environment(\.stowColors) private var colors
    @Environment(\.calm) private var calm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if card {
                VStack(alignment: .leading, spacing: 12) {
                    if !calm { thumbnail(cornerRadius: 14).padding(.top, 8) }
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(colors.chip).frame(width: 36, height: 36)
                        lines
                    }
                    .padding(.bottom, calm ? 12 : 20)
                }
                .padding(.horizontal, 16)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    if !calm { thumbnail(cornerRadius: 10).frame(width: 156) }
                    lines.padding(.top, 2)
                }
                .padding(.leading, 16)
                .padding(.trailing, 44)
                .padding(.vertical, 8)
            }
        }
        .phaseAnimator(reduceMotion ? [false] : [false, true]) { content, dimmed in
            content.opacity(dimmed ? 0.5 : 1)
        } animation: { _ in
            .easeInOut(duration: 0.9)
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }

    private func thumbnail(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(colors.chip)
            .aspectRatio(16 / 9, contentMode: .fit)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(colors.chip).frame(height: 14)
            RoundedRectangle(cornerRadius: 4).fill(colors.chip).frame(width: 120, height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ErrorText {
    /// The first line of an error, as yt-dlp words it ("This video is unavailable"), else a hint.
    static func short(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? ""
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = (line.hasPrefix("ERROR: ") ? String(line.dropFirst(7)) : line).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Check the connection and try again." : trimmed
    }
}

extension View {
    /// A list row drawn edge to edge on the screen's background, without separators.
    func plainListRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
