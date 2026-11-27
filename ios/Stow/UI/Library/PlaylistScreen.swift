import StowKit
import SwiftUI

/// One of your playlists: Play all, Shuffle, and its videos in order (drag to reorder in Edit,
/// swipe to remove).
struct PlaylistScreen: View {
    let playlistId: String
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.calm) private var calm
    @State private var renaming = false
    @State private var deleting = false

    var body: some View {
        if let playlist = repository.playlistStore.playlist(playlistId) {
            content(playlist)
        } else {
            EmptyState("This playlist was deleted.")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(colors.background)
                .navigationTitle("Playlist")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        let videos = playlist.videoIds.compactMap(repository.item)
        let store = repository.playlistStore
        var actions = shell.actions.playing { shell.play(videos, start: $0) }
        actions.removeFromPlaylist = { item in
            store.remove(playlist.id, videoId: item.id)
            shell.notify("Removed from \(playlist.name)")
        }
        actions.move = { item, offset in store.move(playlist.id, videoId: item.id, by: offset) }
        return List {
            header(playlist, videos: videos).plainListRow()
            if videos.isEmpty {
                EmptyState("Add videos with ⋯ › Save to playlist.").plainListRow()
            }
            ForEach(videos) { item in
                VideoRow(item: item, actions: actions)
                    .plainListRow()
                    .swipeActions {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { actions.removeFromPlaylist?(item) }
                    }
            }
            .onMove { from, to in
                guard let index = from.first else { return }
                let target = to > index ? to - 1 : to
                if target != index { store.move(playlist.id, videoId: videos[index].id, by: target - index) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .environment(\.defaultMinListRowHeight, 0)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if videos.count > 1 { EditButton() }
            Menu("More", systemImage: "ellipsis") {
                Button("Rename", systemImage: "pencil") { renaming = true }
                Button("Delete playlist", systemImage: "trash", role: .destructive) { deleting = true }
            }
        }
        .nameAlert("Rename playlist", isPresented: $renaming, initial: playlist.name) { name in
            store.rename(playlist.id, to: name)
        }
        .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(playlist.id)
                shell.notify("Deleted “\(playlist.name)”")
                shell.back()
            }
        } message: {
            Text("The videos stay downloaded.")
        }
    }

    private func header(_ playlist: Playlist, videos: [VideoItem]) -> some View {
        let totalMs = videos.reduce(0) { $0 + $1.durationMs }
        return VStack(alignment: .leading, spacing: 2) {
            if !calm, let first = videos.first {
                Thumbnail(item: first, cornerRadius: 12)
                    .padding(.bottom, 12)
            }
            Text(playlist.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(colors.text)
                .lineLimit(2)
            Text([Format.count(videos.count, "video"), totalMs > 0 ? Format.duration(ms: totalMs) : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(colors.secondaryText)
            if !videos.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { playButtons(videos) }
                    VStack(alignment: .leading, spacing: 8) { playButtons(videos) }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder private func playButtons(_ videos: [VideoItem]) -> some View {
        PillButton(label: "Play all", systemImage: "play.fill", filled: true) { playAll(videos, shuffle: false) }.fixedSize()
        PillButton(label: "Shuffle", systemImage: "shuffle") { playAll(videos, shuffle: true) }.fixedSize()
    }

    private func playAll(_ videos: [VideoItem], shuffle: Bool) {
        let list = Self.playAllOrder(videos, shuffle: shuffle)
        guard let first = list.first else { return }
        shell.play(list, start: first)
    }

    /// The downloaded ones, as on Android (they play offline); all of them, streamed, while none is downloaded yet.
    static func playAllOrder(_ videos: [VideoItem], shuffle: Bool) -> [VideoItem] {
        let downloaded = videos.filter(\.isPlayable)
        let list = downloaded.isEmpty ? videos : downloaded
        return shuffle ? list.shuffled() : list
    }
}

/// "Save video to…": tick playlists, or make a new one. Saving a video that isn't downloaded
/// downloads it.
struct SaveToPlaylistSheet: View {
    let item: VideoItem
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false

    var body: some View {
        let current = repository.item(item.id) ?? item
        NavigationStack {
            List {
                Section {
                    ForEach(repository.playlists) { playlist in
                        let contains = playlist.videoIds.contains(current.id)
                        Button {
                            toggle(playlist, add: !contains, item: current)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: contains ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(contains ? colors.accent : colors.secondaryText)
                                Text(playlist.name)
                                    .foregroundStyle(colors.text)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(playlist.videoIds.count)")
                                    .font(.footnote)
                                    .foregroundStyle(colors.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(contains ? .isSelected : [])
                    }
                    Button {
                        naming = true
                    } label: {
                        Label("New playlist", systemImage: "plus")
                            .foregroundStyle(colors.text)
                    }
                } footer: {
                    if !current.isPlayable && !current.isDownloading {
                        Text("Saving it also downloads it.")
                    }
                }
                .listRowBackground(colors.raised)
            }
            .scrollContentBackground(.hidden)
            .background(colors.groupedBackground)
            .navigationTitle("Save video to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .nameAlert("New playlist", isPresented: $naming, confirm: "Create") { name in
            let playlist = repository.createPlaylist(name, with: current)
            shell.notify("Saved to \(playlist.name)")
            dismiss()
        }
    }

    private func toggle(_ playlist: Playlist, add: Bool, item: VideoItem) {
        if add {
            repository.addToPlaylist(playlist.id, item)
        } else {
            repository.playlistStore.remove(playlist.id, videoId: item.id)
        }
        shell.notify(add ? "Saved to \(playlist.name)" : "Removed from \(playlist.name)")
    }
}
