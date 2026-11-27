import StowKit
import SwiftUI

/// Like YouTube's Home: everything YouTube recommends, from any channel. Chips after "All" are
/// your channel groups: one shows only its channels, newest first, ending in "You're all caught
/// up". Long-press a group's chip to edit it; "+" makes one.
struct HomeScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @SceneStorage("home.group") private var groupId = ""
    @State private var showWatched = false

    var body: some View {
        let groups = repository.groups
        let group = groups.first { $0.id == groupId }
        let actions = shell.actions
        ScrollView {
            LazyVStack(spacing: 0) {
                UpdateBanner()
                ChipRow {
                    Chip(label: "All", selected: group == nil) { groupId = "" }
                    ForEach(groups) { g in
                        Chip(label: g.name, selected: group?.id == g.id) {
                            groupId = group?.id == g.id ? "" : g.id
                            showWatched = false
                        }
                        .contextMenu {
                            Button("Edit group", systemImage: "pencil") { shell.open(.group(g.id)) }
                        }
                    }
                    Chip(label: groups.isEmpty ? "New group" : "", selected: false, systemImage: "plus") {
                        shell.namingNewGroup = true
                    }
                    .accessibilityLabel("New group")
                }
                if let group {
                    groupFeed(group, actions: actions)
                } else {
                    allFeed(actions: actions)
                }
            }
        }
        .background(colors.background)
        .refreshable { await shell.refreshFromMac() }
        .navigationTitle("Home")
        .toolbar { TabToolbar(shell: shell) }
    }

    @ViewBuilder private func allFeed(actions: VideoActions) -> some View {
        let recommended = repository.recommended
        // YouTube's recommendations; your channels' newest until the Mac has shared them.
        let videos = recommended.isEmpty ? repository.everything.filter { !$0.watched } : recommended
        if recommended.isEmpty {
            FootnoteText("YouTube's recommendations come through the Mac: keep Stow there signed in to YouTube. Until then, here's what's new from your channels.")
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }
        ForEach(videos) { VideoCard(item: $0, actions: actions) }
        Text(videos.isEmpty ? "Nothing here yet. Pull down to ask the Mac for videos." : "That's everything for now. Pull down for a fresh batch.")
            .font(.footnote)
            .foregroundStyle(colors.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
    }

    @ViewBuilder private func groupFeed(_ group: ChannelGroup, actions: VideoActions) -> some View {
        if group.channels.isEmpty {
            EmptyState("“\(group.name)” has no channels yet.")
            Button("Add channels") { shell.open(.group(group.id)) }
                .font(.body.weight(.medium))
        } else {
            let videos = repository.groupVideos(group)
            let watched = videos.filter(\.watched)
            ForEach(videos.filter { !$0.watched }) { VideoCard(item: $0, actions: actions) }
            CaughtUp(what: "That's everything new from \(group.name).", watchedCount: watched.count, showingWatched: showWatched) {
                withAnimation { showWatched.toggle() }
            }
            if showWatched {
                ForEach(watched) { VideoCard(item: $0, actions: actions) }
            }
        }
    }
}

/// The end of a group's feed, instead of an endless one.
private struct CaughtUp: View {
    let what: String
    let watchedCount: Int
    let showingWatched: Bool
    let onToggle: () -> Void
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors

    var body: some View {
        // Read so the time updates as you watch.
        let _ = repository.stats.changes
        let todaySeconds = repository.stats.today().seconds
        VStack(spacing: 4) {
            Circle()
                .fill(StowGradient.linear)
                .frame(width: 60, height: 60)
                .overlay { Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(.white) }
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            Text("You're all caught up")
                .font(.title3.weight(.semibold))
                .foregroundStyle(colors.text)
            Text(what)
                .font(.subheadline)
                .foregroundStyle(colors.secondaryText)
                .multilineTextAlignment(.center)
            Button("Watched today: \(Format.minutes(seconds: todaySeconds))") { shell.open(.report) }
                .font(.footnote)
                .foregroundStyle(colors.secondaryText)
                .padding(4)
            if watchedCount > 0 {
                Button(showingWatched ? "Hide watched videos" : "Show watched videos (\(watchedCount))", action: onToggle)
                    .font(.body.weight(.medium))
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }
}
