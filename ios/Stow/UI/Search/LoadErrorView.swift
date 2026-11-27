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
