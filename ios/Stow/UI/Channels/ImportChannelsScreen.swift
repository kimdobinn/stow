import StowKit
import SwiftUI

/// Standalone, signed in: the account's YouTube subscriptions as a checklist. Nothing is picked at
/// first; channels already followed show as added.
struct ImportChannelsScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @State private var selection: ImportSelection?
    @State private var loadError: String?
    @State private var query = ""
    @State private var attempt = 0

    var body: some View {
        Group {
            if let selection {
                list(selection)
            } else if let loadError {
                LoadErrorView(title: "Couldn't get your subscriptions from YouTube.", message: loadError) { attempt += 1 }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 24)
            } else {
                LoadingRow(text: "Getting your subscriptions from YouTube…")
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 24)
            }
        }
        .background(colors.groupedBackground)
        .navigationTitle("Import from YouTube")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await load() }
    }

    private func list(_ selection: ImportSelection) -> some View {
        let shown = filtered(selection.channels)
        return List {
            Section {
                ForEach(shown) { channel in
                    let added = selection.isAdded(channel.id)
                    let picked = selection.isPicked(channel.id)
                    Button {
                        self.selection?.toggle(channel.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(picked ? (added ? colors.secondaryText : colors.accent) : colors.secondaryText)
                            ChannelAvatar(url: channel.avatarURL, name: channel.title, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(channel.title).foregroundStyle(colors.text).lineLimit(1)
                                if let handle = channel.handle {
                                    Text(handle).font(.caption).foregroundStyle(colors.secondaryText).lineLimit(1)
                                }
                            }
                            Spacer()
                            if added { Text("Added").font(.caption).foregroundStyle(colors.secondaryText) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(added)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            } footer: {
                Text("\(Format.count(selection.channels.count, "subscription")). Stow checks the channels you add about every 15 minutes.")
            }
            .listRowBackground(colors.raised)
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "Search subscriptions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select all", systemImage: "checkmark.circle") { self.selection?.selectAll(matching: shown.map(\.id)) }
                    Button("Select none", systemImage: "circle") { self.selection?.selectNone() }
                } label: {
                    Image(systemName: "checklist")
                }
                .accessibilityLabel("Select")
            }
        }
        .safeAreaInset(edge: .bottom) {
            let count = selection.toAdd.count
            Button {
                add(selection.toAdd)
            } label: {
                Text(count == 1 ? "Add 1 channel" : "Add \(count) channels").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(count == 0)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(colors.groupedBackground)
        }
    }

    private func filtered(_ channels: [ChannelInfo]) -> [ChannelInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return channels }
        return channels.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.handle?.localizedCaseInsensitiveContains(q) ?? false) }
    }

    private func load() async {
        guard let standalone = repository.standalone else { return }
        loadError = nil
        do {
            let channels = try await standalone.loadSubscriptions()
            selection = ImportSelection(channels: channels, followed: standalone.followedIds)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func add(_ channels: [ChannelInfo]) {
        guard let standalone = repository.standalone else { return }
        let count = standalone.addChannels(channels)
        shell.notify(count == 1 ? "Added 1 channel" : "Added \(count) channels")
        shell.back()
    }
}
