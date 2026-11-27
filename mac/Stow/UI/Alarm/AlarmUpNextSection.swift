import SwiftUI

/// What the alarm would play if it rang now.
struct AlarmUpNextSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preview = model.upNextPreview
        Section {
            if preview.videos.isEmpty {
                emptyRow
            } else {
                ForEach(Array(preview.videos.enumerated()), id: \.element.id) { index, video in
                    UpNextRow(position: index + 1, video: video)
                }
            }
        } header: {
            Text("Up Next")
        } footer: {
            footer(preview)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.and.waves.left.and.right")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing to play right now")
                    .font(.body.weight(.semibold))
                Text(model.channels.contains(where: \.morning)
                     ? "If that's still true at alarm time, the alarm sound rings instead."
                     : "No channel is marked Morning. Turn it on in Channels.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func footer(_ preview: AlarmPreview) -> some View {
        if let rule = preview.fallbackRule {
            Label {
                Text("Nothing new from Morning channels, so a fallback rule picked this: \(describe(rule)).")
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
        } else {
            Text("Durations are checked just before the alarm, so a video may still be skipped then.")
        }
    }

    private func describe(_ rule: FallbackRule) -> String {
        let channel = rule.channelId.flatMap { id in model.channels.first { $0.id == id }?.title }
        return AlarmText.describe(rule, channelTitle: channel).lowercasedFirst
    }
}

private struct UpNextRow: View {
    let position: Int
    let video: Video
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 14) {
            Text("\(position)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Thumbnail(url: video.thumbnailURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if video.isMembersOnly {
                Image(systemName: "star.fill")
                    .foregroundStyle(.green)
                    .help("Members only")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open on YouTube") { openURL(video.watchURL) }
        }
    }

    private var subtitle: String {
        guard let date = video.publishedAt else { return video.channelTitle }
        return "\(video.channelTitle) · \(date.formatted(.relative(presentation: .numeric)))"
    }
}

private struct Thumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
