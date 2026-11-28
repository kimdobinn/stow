import StowKit
import SwiftUI

/// Your downloads (sortable, groupable by channel, filterable) and your playlists, like
/// YouTube's You tab. Long press a download (or tap Select) to pick several to delete; swipe one
/// to delete it.
struct DownloadsScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.channelAvatars) private var avatars
    @Environment(\.downloadHold) private var hold
    @State private var filter: WatchFilter = .all
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var confirmDelete = false
    @State private var namingPlaylist = false
    @State private var storage: Int64?

    var body: some View {
        let all = repository.downloadItems
        let downloading = all.filter { $0.isDownloading || $0.state == .failed }
            .sorted { ($0.local?.updatedAt ?? .distantPast) > ($1.local?.updatedAt ?? .distantPast) }
        let playable = all.filter(\.isPlayable)
        let downloaded = Feeds.sorted(Feeds.filtered(playable, by: filter), by: repository.prefs.downloadSort)
        List {
            if !selecting {
                if let banner = DownloadText.banner(hold, waiting: downloading.filter(\.isDownloading).count) {
                    bannerRow(banner)
                }
                SectionHeader("Playlists").plainRow()
                playlistsRow(playable: playable).plainRow()
                if !downloading.isEmpty {
                    SectionHeader("Downloading · \(downloading.count)").plainRow()
                    ForEach(downloading) { item in
                        VideoRow(item: item, actions: shell.actions)
                            .plainRow()
                            .swipeActions(edge: .trailing) {
                                Button(item.isDownloading ? "Cancel" : "Remove", systemImage: "xmark", role: .destructive) {
                                    shell.actions.delete(item)
                                }
                            }
                    }
                }
            }
            SectionHeader(text: "Downloaded · \(playable.count)") { sortMenu }.plainRow()
            ChipRow {
                ForEach(WatchFilter.allCases, id: \.self) { option in
                    Chip(label: option.label, selected: filter == option) { withoutAnimation { filter = option } }
                }
            }
            .plainRow()
            if downloaded.isEmpty {
                EmptyState(playable.isEmpty ? "No downloads yet. Tap the arrow on any video to download it."
                                            : "Nothing matches this filter.").plainRow()
            } else if repository.prefs.groupByChannel {
                ForEach(byChannel(downloaded), id: \.channelId) { group in
                    channelHeader(group.channelId, group.items).plainRow()
                    ForEach(group.items) { item in row(item, showChannel: false) }
                }
            } else {
                ForEach(downloaded) { item in row(item, showChannel: true) }
            }
            footer.plainRow()
        }
        .listStyle(.plain)
        // Rows coming and going (a download finishing, a delete from the menu or several at once,
        // a new sort) slide into place instead of jumping. Only when the lists change, not on
        // every percent; a filter chip switches at once (withoutAnimation).
        .animation(Motion.standard, value: downloading.map(\.id))
        .animation(Motion.standard, value: downloaded.map(\.id))
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .environment(\.defaultMinListRowHeight, 0)
        .navigationTitle(selecting ? (picked.isEmpty ? "Select videos" : "\(picked.count) selected") : "Downloads")
        .navigationBarTitleDisplayMode(selecting ? .inline : .automatic)
        .toolbar {
            if selecting {
                selectionToolbar(downloaded)
            } else {
                TabToolbar(shell: shell)
                if !playable.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Select") { withAnimation(Motion.standard) { selecting = true } }.tint(colors.text)
                    }
                }
            }
        }
        .task(id: "\(playable.count)/\(downloading.count)/\(downloading.first?.local?.progress ?? 0 / 10)") {
            storage = repository.storageUsedBytes()
        }
        .onChange(of: playable.map(\.id)) { _, ids in
            picked.formIntersection(ids)
            if ids.isEmpty { selecting = false }
        }
        .confirmationDialog(deleteTitle(playable), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deletePicked(playable) }
        } message: {
            Text(deleteMessage(playable))
        }
        .nameAlert("New playlist", isPresented: $namingPlaylist, confirm: "Create") { name in
            let playlist = repository.createPlaylist(name)
            shell.open(.playlist(playlist.id))
        }
    }

    // MARK: - Rows

    private func row(_ item: VideoItem, showChannel: Bool) -> some View {
        VideoRow(item: item, actions: shell.actions, showChannel: showChannel,
                 selection: RowSelection(active: selecting, selected: picked.contains(item.id)) { toggle([item.id]) })
            .plainRow()
            .swipeActions(edge: .trailing) {
                if !selecting {
                    Button("Delete", systemImage: "trash", role: .destructive) { shell.actions.delete(item) }
                }
            }
            .swipeActions(edge: .leading) {
                if !selecting {
                    Button(item.watched ? "Unwatched" : "Watched", systemImage: item.watched ? "eye.slash" : "eye") {
                        shell.actions.setWatched(item, !item.watched)
                    }
                    .tint(colors.accent)
                }
            }
    }

    private func bannerRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hold == .waitingForWiFi ? "wifi" : "wifi.slash")
                .foregroundStyle(colors.accent)
            Text(text)
                .font(.footnote)
                .foregroundStyle(colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(colors.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .plainRow()
    }

    private func channelHeader(_ channelId: String, _ items: [VideoItem]) -> some View {
        let allPicked = items.allSatisfy { picked.contains($0.id) }
        return Button {
            if selecting { toggle(items.map(\.id), on: !allPicked) } else { shell.openChannel(channelId) }
        } label: {
            HStack(spacing: 10) {
                if selecting { SelectionMark(selected: allPicked).transition(SelectionMark.transition) }
                ChannelAvatar(url: avatars[channelId], name: items[0].video.channelTitle, size: 28)
                Text(items[0].video.channelTitle)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(colors.text)
                    .lineLimit(1)
                Spacer()
                Text("\(items.count)").font(.footnote).foregroundStyle(colors.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let storage { FootnoteText("\(Format.bytes(storage)) used on this phone") }
            FootnoteText(DownloadText.backgroundNote)
        }
        .padding(16)
        .padding(.bottom, 8)
    }

    private var sortMenu: some View {
        @Bindable var prefs = repository.prefs
        return Menu {
            Picker("Sort by", selection: $prefs.downloadSort) {
                ForEach(DownloadSort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            Toggle("Group by channel", isOn: $prefs.groupByChannel)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(prefs.downloadSort.label).lineLimit(1)
            }
                .font(.footnote.weight(.medium))
                .foregroundStyle(colors.text)
                .padding(.horizontal, 8)
                .frame(minHeight: 36)
        }
        .layoutPriority(1)
    }

    // MARK: - Playlists

    private func playlistsRow(playable: [VideoItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                Button { namingPlaylist = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colors.chip)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay { Image(systemName: "plus").font(.system(size: 28, weight: .medium)).foregroundStyle(colors.text) }
                        Text("New playlist").font(.footnote.weight(.medium)).foregroundStyle(colors.text)
                    }
                    .frame(width: 150)
                }
                .buttonStyle(.plain)
                ForEach(repository.playlists) { playlist in
                    PlaylistCard(playlist: playlist, cover: playlist.videoIds.lazy.compactMap(repository.item).first) {
                        shell.open(.playlist(playlist.id))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Picking several

    @ToolbarContentBuilder
    private func selectionToolbar(_ shown: [VideoItem]) -> some ToolbarContent {
        let allPicked = !shown.isEmpty && shown.allSatisfy { picked.contains($0.id) }
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { stopSelecting() }.fontWeight(.semibold)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(allPicked ? "Deselect all" : "Select all") { toggle(shown.map(\.id), on: !allPicked) }
            Button("Delete", systemImage: "trash") { confirmDelete = true }
                .tint(colors.destructive)
                .disabled(picked.isEmpty)
        }
    }

    private func toggle(_ ids: [String], on: Bool? = nil) {
        if !selecting { withAnimation(Motion.standard) { selecting = true } }
        let add = on ?? !ids.allSatisfy(picked.contains)
        if add { picked.formUnion(ids) } else { picked.subtract(ids) }
    }

    private func stopSelecting() {
        withAnimation(Motion.standard) {
            selecting = false
            picked = []
        }
    }

    private func pickedItems(_ playable: [VideoItem]) -> [VideoItem] {
        playable.filter { picked.contains($0.id) }
    }

    private func deleteTitle(_ playable: [VideoItem]) -> String {
        "Delete \(Format.count(pickedItems(playable).count, "video"))?"
    }

    private func deleteMessage(_ playable: [VideoItem]) -> String {
        let bytes = pickedItems(playable).reduce(Int64(0)) { $0 + ($1.local?.sizeBytes ?? 0) }
        return bytes > 0 ? "Frees \(Format.bytes(bytes)) on this phone." : "They're removed from this phone."
    }

    private func deletePicked(_ playable: [VideoItem]) {
        let items = pickedItems(playable)
        if items.contains(where: { $0.id == shell.player?.currentId }) { shell.closePlayer() }
        items.forEach { repository.deleteDownload($0.id) }
        shell.notify(items.count == 1 ? "Deleted from downloads" : "Deleted \(items.count) videos")
        stopSelecting()
    }

    private func byChannel(_ items: [VideoItem]) -> [(channelId: String, items: [VideoItem])] {
        Dictionary(grouping: items, by: \.video.channelId)
            .map { (channelId: $0.key, items: $0.value) }
            .sorted { $0.items[0].video.channelTitle.localizedCaseInsensitiveCompare($1.items[0].video.channelTitle) == .orderedAscending }
    }
}

/// A playlist on Downloads: its first video's thumbnail and how many it holds.
private struct PlaylistCard: View {
    let playlist: Playlist
    let cover: VideoItem?
    let action: () -> Void
    @Environment(\.stowColors) private var colors
    @Environment(\.calm) private var calm

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colors.chip)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { if !calm, let cover { RemoteImage(cover.video.thumbnailURL) } }
                    .overlay(alignment: .bottomTrailing) {
                        Label("\(playlist.videoIds.count)", systemImage: "list.and.film")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 4)
                Text(playlist.name).font(.footnote.weight(.medium)).foregroundStyle(colors.text).lineLimit(1)
                Text(Format.count(playlist.videoIds.count, "video")).font(.caption).foregroundStyle(colors.secondaryText)
            }
            .frame(width: 150)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// A list row drawn edge to edge on the screen's background, without separators.
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
