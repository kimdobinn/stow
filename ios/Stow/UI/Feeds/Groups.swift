import StowKit
import SwiftUI

/// Settings › Channel groups: every group, to open, reorder or add.
struct GroupsScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @State private var creating = false

    var body: some View {
        let groups = repository.groups
        List {
            Section {
                ForEach(groups) { group in
                    NavigationLink(value: Route.group(group.id)) {
                        LabeledContent {
                            Text(Format.count(group.channels.count, "channel"))
                        } label: {
                            Text(group.name).lineLimit(1)
                        }
                    }
                }
                .onMove { from, to in
                    guard let index = from.first else { return }
                    let target = to > index ? to - 1 : to
                    if target != index { shell.groupActions.move(groups[index].id, by: target - index) }
                }
                .listRowBackground(colors.raised)
            } header: {
                if !groups.isEmpty {
                    Text("Pick a group on Home to see only its channels, newest first.")
                        .textCase(nil)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(colors.groupedBackground)
        .overlay {
            if groups.isEmpty { EmptyState("No groups yet. Tap + to make one, or use “Add channel to a group” on any video.") }
        }
        .navigationTitle("Channel groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if groups.count > 1 { EditButton() }
            Button("New group", systemImage: "plus") { creating = true }
        }
        .nameAlert("New group", isPresented: $creating, confirm: "Create") { name in
            let group = shell.groupActions.create(name)
            shell.open(.group(group.id))
        }
    }
}

/// One group: rename it, its channels (remove, add from any channel Stow knows), delete it.
struct GroupScreen: View {
    let groupId: String
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @State private var renaming = false
    @State private var adding = false
    @State private var deleting = false

    var body: some View {
        if let group = repository.groups.first(where: { $0.id == groupId }) {
            content(group)
        } else {
            EmptyState("This group was deleted.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colors.groupedBackground)
                .navigationTitle("Group")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func content(_ group: ChannelGroup) -> some View {
        let avatars = repository.avatars
        let actions = shell.groupActions
        return List {
            Section {
                ForEach(group.channels) { channel in
                    HStack(spacing: 12) {
                        ChannelAvatar(url: avatars[channel.id], name: channel.title, size: 32)
                        Text(channel.title).lineLimit(1)
                        Spacer()
                        Button {
                            actions.set(group.id, channel: channel, included: false)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(colors.destructive)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(channel.title)")
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { actions.set(group.id, channel: channel, included: false) }
                    }
                }
                Button {
                    adding = true
                } label: {
                    Label("Add channels", systemImage: "plus")
                }
            } header: {
                Text("Channels")
            } footer: {
                Text(repository.mode == .standalone ? "Any video's ⋯ menu can add its channel too. Channels you don't follow yet get followed."
                                                    : "Any video's ⋯ menu can add its channel too. Channels the Mac doesn't follow yet get added there (with Morning off).")
            }
            .listRowBackground(colors.raised)
            Section {
                Button("Delete group", role: .destructive) { deleting = true }
                    .foregroundStyle(colors.destructive)
            }
            .listRowBackground(colors.raised)
        }
        // A channel taken out with its minus button folds away like a swiped one.
        .animation(Motion.standard, value: group.channels.map(\.id))
        .scrollContentBackground(.hidden)
        .background(colors.groupedBackground)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Rename") { renaming = true }
        }
        .nameAlert("Rename group", isPresented: $renaming, initial: group.name) { actions.rename(group.id, to: $0) }
        .sheet(isPresented: $adding) {
            AddChannelsSheet(groupId: group.id).sheetTheme(repository)
        }
        .confirmationDialog("Delete “\(group.name)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                actions.delete(group.id)
                shell.back()
            }
        } message: {
            Text("The channels stay; only the group goes.")
        }
    }
}

/// Every channel Stow knows, ticked when it's in the group.
private struct AddChannelsSheet: View {
    let groupId: String
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let group = repository.groups.first { $0.id == groupId }
        let included = group?.channelIds ?? []
        let known = repository.knownChannels
        NavigationStack {
            List(known) { channel in
                let isIn = included.contains(channel.id)
                Button {
                    if shell.groupActions.set(groupId, channel: GroupChannel(id: channel.id, title: channel.title), included: !isIn) {
                        shell.notify("Following \(channel.title) too")
                    }
                } label: {
                    HStack(spacing: 12) {
                        ChannelAvatar(url: channel.avatarURL ?? repository.avatars[channel.id], name: channel.title, size: 32)
                        Text(channel.title).foregroundStyle(colors.text).lineLimit(1)
                        Spacer()
                        Image(systemName: isIn ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isIn ? colors.accent : colors.secondaryText)
                    }
                }
                .accessibilityAddTraits(isIn ? .isSelected : [])
                .listRowBackground(colors.raised)
            }
            .scrollContentBackground(.hidden)
            .background(colors.groupedBackground)
            .overlay {
                if known.isEmpty {
                    EmptyState(repository.mode == .standalone ? "No channels yet: follow some, or sign in to YouTube for your feeds."
                                                              : "No channels yet: they come from the Mac and your YouTube feeds.")
                }
            }
            .navigationTitle("Add to \(group?.name ?? "group")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// "Add channel to a group": a tick per group, and a new group with this channel in it.
struct GroupPickerSheet: View {
    let channel: GroupChannel
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false

    var body: some View {
        let actions = shell.groupActions
        NavigationStack {
            List {
                Section {
                    ForEach(repository.groups) { group in
                        let isIn = group.channelIds.contains(channel.id)
                        Button {
                            let followed = actions.set(group.id, channel: channel, included: !isIn)
                            shell.notify(isIn ? "Removed from \(group.name)"
                                         : followed ? "Added to \(group.name). Following \(channel.title) too" : "Added to \(group.name)")
                        } label: {
                            HStack {
                                Image(systemName: isIn ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isIn ? colors.accent : colors.secondaryText)
                                Text(group.name).foregroundStyle(colors.text).lineLimit(1)
                                Spacer()
                                Text(Format.count(group.channels.count, "channel"))
                                    .font(.footnote)
                                    .foregroundStyle(colors.secondaryText)
                            }
                        }
                        .accessibilityAddTraits(isIn ? .isSelected : [])
                    }
                    Button {
                        creating = true
                    } label: {
                        Label("New group", systemImage: "plus")
                    }
                } footer: {
                    Text(repository.mode == .standalone ? "Home can show just a group's channels. Stow follows any channel it doesn't follow yet."
                                                        : "Home can show just a group's channels. The Mac adds any channel it doesn't follow yet.")
                }
                .listRowBackground(colors.raised)
            }
            .scrollContentBackground(.hidden)
            .background(colors.groupedBackground)
            .navigationTitle("Add \(channel.title) to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .nameAlert("New group", isPresented: $creating, confirm: "Create") { name in
                let followedBefore = repository.mode != .standalone || repository.followedIds.contains(channel.id)
                actions.create(name, with: channel)
                // Otherwise create's own toast says it's followed too.
                if followedBefore { shell.notify("Added to \(name)") }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
