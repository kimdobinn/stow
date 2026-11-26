import SwiftUI

/// Channel list with morning/auto-download toggles, add-by-URL field, and the subscriptions picker.
struct ChannelsTab: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var selection = Set<Channel.ID>()
    @State private var showsPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            addBar
            channelList
            if model.phone.isPaired { GroupsBar() }
            Text("**Morning:** the alarm can play this channel's new videos. **Groups:** the phone's Home can show just one group's channels. Nothing downloads to the phone by itself: send a video (Send to Phone) or download it on the phone.")
                .font(.callout)
                .foregroundStyle(.secondary)
            subscriptionsBar
        }
        .controlSize(.large)
        .padding(24)
        .sheet(isPresented: $showsPicker) { SubscriptionsPicker() }
    }

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Paste a channel link or @handle", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .disabled(isAdding)
                if isAdding {
                    ProgressView().controlSize(.small)
                }
                Button("Add", action: add)
                    .disabled(trimmedInput.isEmpty || isAdding)
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .noDragScroll()
            }
        }
    }

    private var channelList: some View {
        Table(model.channels, selection: $selection) {
            TableColumn("Channel") { channel in
                ChannelCell(channel: channel)
            }
            TableColumn("Morning") { channel in
                ColumnToggle(isOn: Binding(
                    get: { channel.morning },
                    set: { model.setMorning($0, channelId: channel.id) }
                ))
                .help("Include in the morning alarm")
            }
            .width(90)
            .alignment(.center)
            TableColumn("Groups") { channel in
                GroupsMenu(channel: channel)
            }
            .width(min: 120, ideal: 170)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: Channel.ID.self) { ids in
            if ids.count == 1, let channel = model.channels.first(where: { ids.contains($0.id) }) {
                Link("Open on YouTube", destination: channel.url)
                Divider()
            }
            Button(ids.count > 1 ? "Remove \(ids.count) Channels" : "Remove", role: .destructive) {
                remove(ids)
            }
        }
        .onDeleteCommand { remove(selection) }
        .overlay {
            if model.channels.isEmpty {
                ContentUnavailableView(
                    "No Channels",
                    systemImage: "tray",
                    description: Text("Paste a channel link above, or choose from your subscriptions.")
                )
            }
        }
    }

    private var subscriptionsBar: some View {
        let signedIn = model.signInState == .signedIn
        return HStack {
            Button("Choose from Subscriptions…") { showsPicker = true }
                .disabled(!signedIn)
            if !signedIn {
                Text("Sign in under Account to choose from your subscriptions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func add() {
        let text = trimmedInput
        guard !text.isEmpty, !isAdding else { return }
        isAdding = true
        addError = nil
        Task {
            defer { isAdding = false }
            do {
                try await model.addChannel(input: text)
                input = ""
            } catch {
                addError = error.localizedDescription
            }
        }
    }

    private func remove(_ ids: Set<Channel.ID>) {
        for id in ids {
            model.removeChannel(id: id)
        }
        selection.subtract(ids)
    }
}

private struct ChannelCell: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            ChannelAvatar(url: channel.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title).font(.title3).lineLimit(1)
                if let handle = channel.handle {
                    Text(handle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Which of the phone's groups a channel is in, as a menu of checkmarks.
private struct GroupsMenu: View {
    @Environment(AppModel.self) private var model
    let channel: Channel

    var body: some View {
        let groups = model.phone.groups
        let names = groups.filter { $0.channels.contains { $0.id == channel.id } }.map(\.name)
        Menu(names.isEmpty ? "None" : names.joined(separator: ", ")) {
            ForEach(groups) { group in
                let included = group.channels.contains { $0.id == channel.id }
                Toggle(group.name, isOn: Binding(
                    get: { included },
                    set: { model.phone.setChannel(GroupChannel(id: channel.id, title: channel.title), inGroup: group.id, $0) }
                ))
            }
            if groups.isEmpty { Text("No groups yet") }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(names.isEmpty ? .secondary : .primary)
        .disabled(!model.phone.isPaired)
        .help(model.phone.isPaired ? "The phone's channel groups this channel is in" : "Groups are for the phone: pair one first")
    }
}

/// The phone's channel groups: add, rename, delete.
private struct GroupsBar: View {
    @Environment(AppModel.self) private var model
    @State private var naming: NamingGroup?
    @State private var name = ""

    private struct NamingGroup: Identifiable {
        var id: String
        var isNew: Bool
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Groups").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.phone.groups) { group in
                        Menu {
                            Button("Rename…") { name = group.name; naming = NamingGroup(id: group.id, isNew: false) }
                            Button("Delete “\(group.name)”", role: .destructive) { model.phone.deleteGroup(id: group.id) }
                        } label: {
                            Text("\(group.name) · \(group.channels.count)")
                        }
                        .menuStyle(.button)
                        .fixedSize()
                    }
                    if model.phone.groups.isEmpty {
                        Text("None yet. Make one here or on the phone.").foregroundStyle(.secondary)
                    }
                }
            }
            .noDragScroll()
            Button("New Group…") { name = ""; naming = NamingGroup(id: "", isNew: true) }
        }
        .alert(naming?.isNew == true ? "New Group" : "Rename Group", isPresented: Binding(
            get: { naming != nil }, set: { if !$0 { naming = nil } }
        )) {
            TextField("Name", text: $name)
            Button(naming?.isNew == true ? "Create" : "Rename") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let naming, !trimmed.isEmpty {
                    if naming.isNew { model.phone.createGroup(name: trimmed) } else { model.phone.renameGroup(id: naming.id, to: trimmed) }
                }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        }
    }
}

/// A switch whose column header is its label.
private struct ColumnToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
    }
}

#if DEBUG
#Preview {
    ChannelsTab()
        .environment(AppModel.preview)
        .frame(width: 640, height: 440)
}
#endif
