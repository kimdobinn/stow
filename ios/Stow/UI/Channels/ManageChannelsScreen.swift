import StowKit
import SwiftUI

/// Standalone: the channels this phone follows, in order. Swipe to remove; Edit to reorder;
/// "+" adds one by URL, @handle or channel ID.
struct ManageChannelsScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors

    var body: some View {
        let standalone = repository.standalone
        let channels = standalone?.channels ?? []
        let errors = standalone?.state.channelErrors ?? [:]
        List {
            Section {
                ForEach(channels) { channel in
                    NavigationLink(value: Route.channel(channel.id)) {
                        HStack(spacing: 14) {
                            ChannelAvatar(url: channel.avatarURL ?? repository.avatars[channel.id], name: channel.title, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(colors.text)
                                    .lineLimit(1)
                                if let error = errors[channel.id] {
                                    Text(error).font(.caption).foregroundStyle(colors.destructive)
                                } else {
                                    Text([channel.handle, Format.count(repository.channel(channel.id)?.recent.count ?? 0, "recent video")]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(colors.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { shell.unfollow(channel.id) }
                    }
                    .contextMenu {
                        Button("Add to a group", systemImage: "square.stack") {
                            shell.grouping = GroupChannel(id: channel.id, title: channel.title)
                        }
                        Button("Remove channel", systemImage: "minus.circle", role: .destructive) { shell.unfollow(channel.id) }
                    }
                }
                .onMove { source, destination in standalone?.moveChannels(fromOffsets: source, toOffset: destination) }
                Button {
                    shell.addingChannel = true
                } label: {
                    Label("Add a channel", systemImage: "plus")
                }
                if standalone?.isSignedIn == true {
                    NavigationLink(value: Route.importChannels) {
                        Label("Import from YouTube", systemImage: "square.and.arrow.down")
                    }
                }
            } footer: {
                Text(channels.isEmpty ? "Follow channels to see their new videos on Home and Subscriptions."
                                      : "Their newest videos show on Home and Subscriptions. Removing a channel keeps its downloads.")
            }
            .listRowBackground(colors.raised)
        }
        .scrollContentBackground(.hidden)
        .background(colors.groupedBackground)
        .navigationTitle("Your channels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !channels.isEmpty { EditButton() }
                Button("Add a channel", systemImage: "plus") { shell.addingChannel = true }
            }
        }
    }
}
