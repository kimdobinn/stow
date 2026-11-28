import StowKit
import SwiftUI

/// A channel's page: its header, then its videos, and its past live streams under Live, like
/// YouTube. For a channel the Mac doesn't follow, its latest videos come from YouTube, on the phone.
struct ChannelScreen: View {
    let channelId: String
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var tab: ChannelTab = .videos
    @State private var oldestFirst = false
    @State private var loading = false
    @State private var loadError: String?
    @State private var attempt = 0
    /// The last name and picture seen: after unfollowing, they stay while YouTube's page loads.
    @State private var knownTitle = ""
    @State private var knownAvatar: String?

    /// What the page loads: again on a retry, and when the channel stops being followed (removed
    /// from this page), so it shows YouTube's videos and the Follow pill like any other channel.
    private struct LoadKey: Equatable {
        var attempt: Int
        /// Standalone only (nil with the Mac, whose channels come and go with its polls).
        var followed: Bool?
    }

    enum ChannelTab: CaseIterable {
        case videos, live

        var label: String {
            switch self {
            case .videos: "Videos"
            case .live: "Live"
            }
        }
    }

    var body: some View {
        let channel = repository.channel(channelId)
        let videos = repository.channelVideos(channelId)
        let current = repository.channelTitle(channelId)
        let title = current.isEmpty ? knownTitle : current
        // Standalone, a channel whose name is known shows its header (and Follow) while loading.
        let showsHeader = channel != nil || !videos.isEmpty || (repository.mode == .standalone && !title.isEmpty)
        Group {
            if !showsHeader {
                // Nothing to show until YouTube answers.
                VStack {
                    if loading {
                        LoadingRow(text: "Getting the latest videos from YouTube…")
                    } else if let loadError {
                        LoadErrorView(title: "Couldn't get this channel's videos from YouTube.", message: loadError) { attempt += 1 }
                    } else {
                        EmptyState("No videos from this channel.")
                    }
                    Spacer()
                }
                .padding(.top, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                page(channel: channel, videos: videos, title: title)
            }
        }
        .background(colors.background)
        .navigationTitle(title.isEmpty ? "Channel" : title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: current, initial: true) { _, name in if !name.isEmpty { knownTitle = name } }
        .onChange(of: channel?.avatarURL ?? repository.avatars[channelId], initial: true) { _, url in if let url { knownAvatar = url } }
        .task(id: LoadKey(attempt: attempt, followed: repository.mode == .standalone ? channel != nil : nil)) { await load(followed: channel != nil) }
    }

    private func page(channel: Channel?, videos: [VideoItem], title: String) -> some View {
        let (uploads, streams) = Feeds.split(videos)
        let listed = tab == .live ? streams : uploads
        let shown = oldestFirst ? Array(listed.reversed()) : listed
        let actions = shell.actions.playing { shell.play(shown, start: $0) }
        return ScrollView {
            LazyVStack(spacing: 0) {
                header(channel: channel, count: videos.count, title: title)
                if channel == nil && repository.mode != .standalone {
                    FootnoteText(repository.channelPages[channelId] != nil
                                 ? "Not followed on the Mac yet. Add it to a group and the Mac follows it."
                                 : "Not followed on the Mac yet: these are its videos from your YouTube feeds and searches. Add it to a group and the Mac follows it.")
                        .padding(.horizontal, 16)
                }
                ChipRow {
                    ForEach(ChannelTab.allCases, id: \.self) { option in
                        Chip(label: option.label, selected: tab == option) { tab = option }
                    }
                    Divider().frame(height: 20).padding(.horizontal, 4)
                    Chip(label: "Latest", selected: !oldestFirst) { oldestFirst = false }
                    Chip(label: "Oldest", selected: oldestFirst) { oldestFirst = true }
                }
                if loading {
                    LoadingRow(text: "Getting the latest videos from YouTube…")
                } else if let loadError {
                    LoadErrorView(title: "Couldn't get this channel's videos from YouTube.", message: loadError) { attempt += 1 }
                }
                if shown.isEmpty && !loading {
                    EmptyState(tab == .live ? "No past live streams." : "No recent videos.")
                }
                ForEach(shown) { VideoRow(item: $0, actions: actions, showChannel: false) }
            }
            .padding(.bottom, 16)
        }
    }

    private func header(channel: Channel?, count: Int, title: String) -> some View {
        let groupNames = repository.groups.filter { $0.channels.contains { $0.id == channelId } }.map(\.name)
        let avatar = channel?.avatarURL ?? repository.avatars[channelId] ?? knownAvatar
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                                   : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            ChannelAvatar(url: avatar, name: title, size: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(colors.text)
                    .lineLimit(2)
                Text([channel?.handle, Format.count(count, "recent video")].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(colors.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if repository.mode == .standalone {
                        followButton(title: title, avatar: avatar)
                    }
                    PillButton(label: groupNames.isEmpty ? "Add to group" : groupNames.joined(separator: ", "),
                               systemImage: groupNames.isEmpty ? "plus" : "checkmark") {
                        shell.grouping = GroupChannel(id: channelId, title: title)
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }

    /// Standalone: "Follow" (filled) for a channel not followed; "Following" opens a menu to remove it.
    @ViewBuilder private func followButton(title: String, avatar: String?) -> some View {
        if repository.followedIds.contains(channelId) {
            Menu {
                Button("Remove channel", systemImage: "minus.circle", role: .destructive) { shell.unfollow(channelId) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text("Following").lineLimit(1)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .background(colors.chip, in: Capsule())
            }
        } else {
            PillButton(label: "Follow", systemImage: "plus", filled: true) {
                shell.follow(channelId, title: title, avatarURL: avatar)
            }
        }
    }

    /// Not followed on the Mac: its latest videos from YouTube (kept half an hour).
    private func load(followed: Bool) async {
        guard !followed else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            try await repository.loadChannelPage(channelId)
        } catch is CancellationError {
        } catch {
            // Left the page: not an error to show.
            guard !Task.isCancelled else { return }
            loadError = ErrorText.short(error)
        }
    }
}
