import SwiftUI

/// A YouTube-style feed: "New" videos first (✕ moves one down into Recent), then one row of
/// recent videos per channel, reorderable by dragging. Chips at the top filter by channel.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var confirmsClear = false
    @State private var channelFilter: Channel.ID?
    /// The Recent row a channel is being dragged over. Kept here (not per row) so it can be
    /// cleared when the order changes: a row that moves never gets its "drag exited" callback.
    @State private var dropTarget: Channel.ID?

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

    /// Channels with recent videos, in the user's order.
    private var shelves: [(channel: Channel, videos: [Video])] {
        model.channels
            .filter { channelFilter == nil || $0.id == channelFilter }
            .map { ($0, model.recentVideos(channelId: $0.id)) }
            .filter { !$0.videos.isEmpty }
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
                    if shelves.isEmpty && newVideos.isEmpty {
                        ContentUnavailableView("No Videos Yet", systemImage: "tray",
                                               description: Text("Videos appear after the next check."))
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if !shelves.isEmpty {
                        recent
                    }
                }
                .padding(24)
            }
        }
    }

    /// One row per channel; drag a row's header to reorder (saved as the channel order).
    private var recent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent").font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 16) {
                ForEach(shelves, id: \.channel.id) { shelf in
                    ChannelShelf(channel: shelf.channel, videos: shelf.videos,
                                 isDropTarget: dropTarget == shelf.channel.id,
                                 isWatched: { model.isWatched(videoId: $0.id) },
                                 onToggleWatched: toggleWatched) { video in
                        model.watch(video)
                    } onDrop: { droppedId in
                        dropTarget = nil
                        withAnimation(.snappy) { model.moveChannel(id: droppedId, before: shelf.channel.id) }
                    } onTargeted: { targeted in
                        if targeted {
                            dropTarget = shelf.channel.id
                        } else if dropTarget == shelf.channel.id {
                            dropTarget = nil
                        }
                    }
                }
            }
        }
        .onChange(of: model.channels.map(\.id)) { dropTarget = nil }
        // Hover events only arrive when no drag is in progress, so any of them means a drag is over.
        .onContinuousHover { _ in
            if dropTarget != nil { dropTarget = nil }
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
                        .background(theme.accent, in: Capsule())
                }
            }
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(videos) { video in
                    VideoCard(video: video,
                              isWatched: model.isWatched(videoId: video.id),
                              onOpen: { model.watch(video) },
                              onToggleWatched: { toggleWatched(video) },
                              onDismiss: dismissible ? { model.dismissInbox(videoId: video.id) } : nil)
                }
            }
        }
    }

    private func toggleWatched(_ video: Video) {
        withAnimation(.snappy) { model.setWatched(!model.isWatched(videoId: video.id), videoId: video.id) }
    }
}

/// A channel's name and picture in a column on the left (the drag handle for reordering), and
/// its videos in a horizontal strip beside it.
private struct ChannelShelf: View {
    @Environment(\.appTheme) private var theme
    let channel: Channel
    let videos: [Video]
    let isDropTarget: Bool
    let isWatched: (Video) -> Bool
    let onToggleWatched: (Video) -> Void
    let onOpen: (Video) -> Void
    let onDrop: (String) -> Void
    let onTargeted: (Bool) -> Void

    static let headerWidth: CGFloat = 132

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    /// A soft card per channel: its column, a hairline, then the videos scrolling inside the card.
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            header
                .padding(.horizontal, 14)
            Rectangle()
                .fill(.separator)
                .frame(width: 1)
                .padding(.vertical, 24)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(videos) { video in
                        VideoCard(video: video, isWatched: isWatched(video), onOpen: { onOpen(video) },
                                  onToggleWatched: { onToggleWatched(video) }, onDismiss: nil)
                            .frame(width: 290)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.automatic)
        }
        .background(isDropTarget ? theme.accent.opacity(0.08) : Color.primary.opacity(0.035), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isDropTarget ? theme.accent : Color.primary.opacity(0.08),
                               lineWidth: isDropTarget ? 2 : 1)
        }
        .overlay(alignment: .top) {
            if isDropTarget {
                Capsule().fill(theme.accent).frame(height: 3).offset(y: -9)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != channel.id else { return false }
            onDrop(id)
            return true
        } isTargeted: { onTargeted($0) }
    }

    private var header: some View {
        VStack(spacing: 8) {
            ChannelAvatar(url: channel.avatarURL, size: 64)
            Text(channel.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("\(videos.count) videos")
                .font(.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(width: Self.headerWidth)
        .help("Drag to reorder")
        .contentShape(Rectangle())
        .noDragScroll()
        .draggable(channel.id) {
            HStack(spacing: 8) {
                ChannelAvatar(url: channel.avatarURL, size: 24)
                Text(channel.title).font(.headline)
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let video: Video
    let isWatched: Bool
    let onOpen: () -> Void
    let onToggleWatched: () -> Void
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
                        .foregroundStyle(isWatched ? .secondary : .primary)
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
        .task(id: isHovered) {
            // Resting on a video looks it up, so clicking it plays without the wait.
            guard isHovered, (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            model.prefetchStream(video)
        }
        .help(video.title)
        .contextMenu {
            Button("Play", action: onOpen)
            Button("Open on YouTube") { openURL(video.watchURL) }
            Button(isWatched ? "Mark as Unwatched" : "Mark as Watched", action: onToggleWatched)
            Button(model.phone.isSent(videoId: video.id) ? "Send to Phone Again" : "Send to Phone") {
                model.phone.send(videoId: video.id)
            }
            .disabled(!model.phone.isPaired || !model.canSendToPhone(videoId: video.id, isMembersOnly: video.isMembersOnly))
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
                .opacity(isWatched ? 0.55 : 1)
            }
            .background(.black)
            // YouTube's "watched" bar along the bottom of the thumbnail.
            .overlay(alignment: .bottom) {
                if isWatched {
                    Rectangle().fill(Color.red).frame(height: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                if video.isMembersOnly {
                    MembersBadge(access: model.memberAccess(videoId: video.id)).padding(8).padding(.bottom, isWatched ? 4 : 0)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let status = PhoneBadge.Status(video: video.id, phone: model.phone) {
                    PhoneBadge(status: status).padding(8).padding(.bottom, isWatched ? 4 : 0)
                }
            }
            .overlay(alignment: .topLeading) {
                if isHovered {
                    Button(action: onToggleWatched) {
                        Image(systemName: isWatched ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help(isWatched ? "Mark as unwatched" : "Mark as watched")
                    .padding(8)
                } else if isWatched {
                    WatchedBadge().padding(8)
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

    /// "Channel · 2 days ago", or "Channel · Streamed 2 days ago" for a past live broadcast.
    private var subtitle: String {
        let when = video.publishedAt?.formatted(.relative(presentation: .named))
        let streamed = video.liveStatus == .wasLive
        let detail = streamed ? ["Streamed", when].compactMap(\.self).joined(separator: " ") : when
        return [video.channelTitle, detail].compactMap(\.self).joined(separator: " · ")
    }
}

/// Where a video sent to the phone is: on its way, downloading, on the phone, or failed.
private struct PhoneBadge: View {
    enum Status {
        case sending, downloading, onPhone, failed(String?)

        @MainActor
        init?(video id: String, phone: PhoneSync) {
            guard phone.isSent(videoId: id) else { return nil }
            switch phone.download(videoId: id)?.state {
            case nil, .queued: self = .sending
            case .downloading: self = .downloading
            case .downloaded: self = .onPhone
            case .failed: self = .failed(phone.download(videoId: id)?.error)
            case .deleted: return nil
            }
        }
    }

    let status: Status

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .help(help)
    }

    private var title: String {
        switch status {
        case .sending: "Sending"
        case .downloading: "Downloading"
        case .onPhone: "On phone"
        case .failed: "Failed"
        }
    }

    private var symbol: String {
        switch status {
        case .sending: "iphone.radiowaves.left.and.right"
        case .downloading: "arrow.down.circle"
        case .onPhone: "iphone"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var background: Color {
        if case .failed = status { return .red.opacity(0.85) }
        return .black.opacity(0.65)
    }

    private var help: String {
        switch status {
        case .sending: "Sent to the phone; it starts downloading when it's online."
        case .downloading: "The phone is downloading this video."
        case .onPhone: "Downloaded on the phone."
        case .failed(let error): "The phone couldn't download it\(error.map { ": \($0)" } ?? ".")"
        }
    }
}

private struct WatchedBadge: View {
    var body: some View {
        Label("Watched", systemImage: "checkmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.65), in: Capsule())
    }
}

/// Members only, or locked when it's for a higher membership level than the account's.
struct MembersBadge: View {
    var access: MemberAccess?

    var body: some View {
        if access == .nowPublic {
            EmptyView()
        } else if case .locked(let level) = access {
            Label("Higher tier", systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gray, in: Capsule())
                .help("Needs \(level.map { "the “\($0)” membership level" } ?? "a higher membership level"). It isn't sent to the phone or played by the alarm.")
        } else {
            Label("Members only", systemImage: "star.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green, in: Capsule())
        }
    }
}

#if DEBUG
#Preview {
    InboxView()
        .environment(AppModel.preview)
        .frame(width: 900, height: 600)
}
#endif
