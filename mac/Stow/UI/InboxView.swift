import SwiftUI

/// A YouTube-style feed: "New" videos first (✕ moves one down into the feed), then every
/// channel's recent videos. Chips at the top filter by channel.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var confirmsClear = false
    @State private var channelFilter: Channel.ID?

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 20, alignment: .top)]

    var body: some View {
        content
            .toolbar {
                ToolbarItem {
                    Button("Clear New", systemImage: "checkmark.circle") { confirmsClear = true }
                        .help("Move every new video into Recent")
                        .disabled(model.inbox.isEmpty)
                }
            }
            .confirmationDialog("Move \(model.inbox.count) new videos into Recent?", isPresented: $confirmsClear) {
                Button("Clear New") { model.dismissAllInbox() }
            }
    }

    private var newVideos: [Video] {
        model.inbox.map(\.video).filter(matchesFilter)
    }

    private var recentVideos: [Video] {
        model.recentVideos.filter(matchesFilter)
    }

    private func matchesFilter(_ video: Video) -> Bool {
        channelFilter == nil || video.channelId == channelFilter
    }

    @ViewBuilder
    private var content: some View {
        if model.channels.isEmpty {
            ContentUnavailableView("No Channels Yet", systemImage: "person.2",
                                   description: Text("Add channels in the Channels section."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ChannelChips(channels: model.channels, selection: $channelFilter)
                    if !newVideos.isEmpty {
                        section("New", count: newVideos.count, videos: newVideos, dismissible: true)
                    }
                    if recentVideos.isEmpty && newVideos.isEmpty {
                        ContentUnavailableView("No Videos Yet", systemImage: "tray",
                                               description: Text("Videos appear after the next check."))
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if !recentVideos.isEmpty {
                        section("Recent", count: nil, videos: recentVideos, dismissible: false)
                    }
                }
                .padding(24)
            }
        }
    }

    private func section(_ title: String, count: Int?, videos: [Video], dismissible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title2.weight(.bold))
                if let count {
                    Text("\(count)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(videos) { video in
                    VideoCard(video: video,
                              onOpen: { openURL(video.watchURL) },
                              onDismiss: dismissible ? { model.dismissInbox(videoId: video.id) } : nil)
                }
            }
        }
    }
}

/// "All" plus one chip per channel, like YouTube's filter bar.
private struct ChannelChips: View {
    let channels: [Channel]
    @Binding var selection: Channel.ID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isSelected: selection == nil) { selection = nil }
                ForEach(channels) { channel in
                    chip(channel.title, avatar: channel.avatarURL, isSelected: selection == channel.id) {
                        selection = channel.id
                    }
                }
            }
        }
    }

    private func chip(_ title: String, avatar: URL? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let avatar {
                    ChannelAvatar(url: avatar, size: 20)
                }
                Text(title).font(.body.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color(nsColor: .windowBackgroundColor) : .primary)
            .background(isSelected ? Color.primary : Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct VideoCard: View {
    let video: Video
    let onOpen: () -> Void
    /// nil for videos that aren't in "New".
    let onDismiss: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(video.title)
        .contextMenu {
            Button("Open on YouTube", action: onOpen)
            if let onDismiss {
                Button("Move to Recent", action: onDismiss)
            }
        }
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                if video.isMembersOnly {
                    MembersBadge().padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isHovered, let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Move to Recent")
                    .padding(8)
                }
            }
            .shadow(color: .black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 8 : 3, y: 2)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    private var subtitle: String {
        guard let date = video.publishedAt else { return video.channelTitle }
        return "\(video.channelTitle) · \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct MembersBadge: View {
    var body: some View {
        Label("Members only", systemImage: "star.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green, in: Capsule())
    }
}

#if DEBUG
#Preview {
    InboxView()
        .environment(AppModel.preview)
        .frame(width: 900, height: 600)
}
#endif
