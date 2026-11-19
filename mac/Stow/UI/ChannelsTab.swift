import SwiftUI

/// Channel list with morning/phone toggles, add-by-URL field, and the subscriptions picker.
struct ChannelsTab: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var selection = Set<Channel.ID>()
    @State private var showsPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            addBar
            channelList
            subscriptionsBar
        }
        .padding(16)
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
            }
        }
    }

    private var channelList: some View {
        List(selection: $selection) {
            ForEach(model.channels) { channel in
                ChannelRow(channel: channel)
            }
        }
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
                Text("Sign in on the Account tab to choose from your subscriptions.")
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

private struct ChannelRow: View {
    @Environment(AppModel.self) private var model
    let channel: Channel

    var body: some View {
        HStack(spacing: 10) {
            ChannelAvatar(url: channel.avatarURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.title).lineLimit(1)
                if let handle = channel.handle {
                    Text(handle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("Morning", isOn: Binding(
                get: { channel.morning },
                set: { model.setMorning($0, channelId: channel.id) }
            ))
            .help("Include in the morning alarm")
            Toggle("Phone", isOn: Binding(
                get: { channel.phone },
                set: { model.setPhone($0, channelId: channel.id) }
            ))
            .help("Send new videos to the phone")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview {
    ChannelsTab()
        .environment(AppModel.preview)
        .frame(width: 640, height: 440)
}
#endif
