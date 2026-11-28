import StowKit
import SwiftUI

/// Like YouTube's Subscriptions: new videos from every channel you subscribe to (YouTube's feed)
/// and every channel on the Mac, newest first. The channel pictures on top filter it; "All"
/// lists the channels.
struct SubscriptionsScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @SceneStorage("subscriptions.channel") private var selected = ""

    var body: some View {
        let channels = repository.subscribedChannels
        let feed = repository.subscriptionsFeed
        let shown = selected.isEmpty ? feed : feed.filter { $0.video.channelId == selected }
        let actions = shell.actions
        ScrollView {
            LazyVStack(spacing: 0) {
                if !channels.isEmpty {
                    HStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(channels) { channel in
                                    ChannelBubble(channel: channel, selected: selected == channel.id, dimmed: !selected.isEmpty && selected != channel.id) {
                                        withAnimation(.snappy) { selected = selected == channel.id ? "" : channel.id }
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                        }
                        Button("All") { shell.open(repository.mode == .standalone ? .channelsManage : .channels) }
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 14)
                            .accessibilityLabel("All channels")
                    }
                }
                if !selected.isEmpty {
                    HStack {
                        Text(channels.first { $0.id == selected }?.title ?? repository.channelTitle(selected))
                            .font(.body.weight(.medium))
                            .foregroundStyle(colors.text)
                            .lineLimit(1)
                        Spacer()
                        Button("View channel") { shell.openChannel(selected) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                if shown.isEmpty {
                    EmptyState(repository.mode == .standalone ? "No videos yet. Follow channels, or pull down to check them."
                                                              : "No videos yet. Pull down to ask the Mac for new ones.")
                }
                ForEach(shown) { VideoCard(item: $0, actions: actions) }
            }
        }
        .background(colors.background)
        .refreshable { await shell.refresh() }
        .navigationTitle("Subscriptions")
        .toolbar { TabToolbar(shell: shell) }
        .onChange(of: channels.map(\.id)) { _, ids in
            if !selected.isEmpty, !ids.contains(selected) { selected = "" }
        }
    }
}

/// A channel on the row above Subscriptions: its picture (ringed when picked) and name.
private struct ChannelBubble: View {
    let channel: KnownChannel
    let selected: Bool
    let dimmed: Bool
    let action: () -> Void
    @Environment(\.stowColors) private var colors

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ChannelAvatar(url: channel.avatarURL, name: channel.title, size: 52)
                    .padding(3)
                    .overlay { if selected { Circle().strokeBorder(colors.accent, lineWidth: 2) } }
                Text(channel.title)
                    .font(.caption2)
                    .foregroundStyle(dimmed ? colors.secondaryText : colors.text)
                    .lineLimit(1)
            }
            .frame(width: 72)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(channel.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Every channel: the Mac's, then the rest you subscribe to.
struct ChannelsScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(\.stowColors) private var colors

    var body: some View {
        let counts = Dictionary(grouping: repository.everything, by: \.video.channelId).mapValues(\.count)
        List(repository.subscribedChannels) { channel in
            NavigationLink(value: Route.channel(channel.id)) {
                HStack(spacing: 14) {
                    ChannelAvatar(url: channel.avatarURL, name: channel.title, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(colors.text)
                            .lineLimit(1)
                        Text(Format.count(counts[channel.id] ?? 0, "recent video"))
                            .font(.caption)
                            .foregroundStyle(colors.secondaryText)
                    }
                }
            }
            .listRowBackground(colors.background)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .overlay {
            if repository.subscribedChannels.isEmpty {
                EmptyState(repository.mode == .standalone ? "No channels yet: follow some, or sign in to YouTube for your feeds."
                                                          : "No channels yet: they come from the Mac and your YouTube feeds.")
            }
        }
        .navigationTitle("All channels")
        .navigationBarTitleDisplayMode(.inline)
    }
}
