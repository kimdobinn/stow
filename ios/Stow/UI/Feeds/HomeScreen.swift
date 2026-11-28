import StowKit
import SwiftUI

/// Like YouTube's Home: everything YouTube recommends, from any channel. Chips after "All" are
/// your channel groups: one shows only its channels, newest first, ending in "You're all caught
/// up". Long-press a group's chip to edit it; "+" makes one.
struct HomeScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.stowColors) private var colors
    @SceneStorage("home.group") private var groupId = ""
    @State private var showWatched = false

    var body: some View {
        let groups = repository.groups
        let group = groups.first { $0.id == groupId }
        let groupVideos = group.map(repository.groupVideos) ?? []
        let actions = shell.actions
        ScrollView {
            LazyVStack(spacing: 0) {
                UpdateBanner()
                StandaloneBanners()
                ChipRow {
                    // Another chip shows its feed at once, as on YouTube (no sliding cards).
                    Chip(label: "All", selected: group == nil) { withoutAnimation { groupId = "" } }
                    ForEach(groups) { g in
                        Chip(label: g.name, selected: group?.id == g.id) {
                            withoutAnimation {
                                groupId = group?.id == g.id ? "" : g.id
                                showWatched = false
                            }
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
                    groupFeed(group, videos: groupVideos, actions: actions)
                } else {
                    allFeed(actions: actions)
                }
            }
            // A video marked watched leaves a group's feed and the cards below close the gap;
            // banners slide in and fold away instead of pushing the feed in one frame.
            .animation(Motion.standard, value: groupVideos.filter { !$0.watched }.map(\.id))
            .animation(Motion.standard, value: BannerKey(updates: updates.showsBanner,
                                                         expired: repository.standalone?.showsExpiredBanner ?? false,
                                                         signIn: repository.standalone?.showsSignInPrompt ?? false))
            .pullUpToRefresh { await shell.refresh() }
        }
        .background(colors.background)
        .refreshable { await shell.refresh() }
        .navigationTitle("Home")
        .toolbar { TabToolbar(shell: shell) }
    }

    @ViewBuilder private func allFeed(actions: VideoActions) -> some View {
        let recommended = repository.recommended
        // YouTube's recommendations; your channels' newest until the Mac has shared them.
        let videos = recommended.isEmpty ? repository.everything.filter { !$0.watched } : recommended
        if repository.mode == .standalone {
            if videos.isEmpty && repository.followedIds.isEmpty {
                StandaloneEmptyHome()
            } else {
                ForEach(videos) { VideoCard(item: $0, actions: actions) }
                Text(videos.isEmpty ? "Nothing new yet. Pull down to check your channels." : "That's everything for now. Pull up to check for new videos.")
                    .font(.footnote)
                    .foregroundStyle(colors.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
            }
        } else {
            macFeed(videos: videos, recommended: recommended, actions: actions)
        }
    }

    @ViewBuilder private func macFeed(videos: [VideoItem], recommended: [VideoItem], actions: VideoActions) -> some View {
        if recommended.isEmpty {
            FootnoteText("YouTube's recommendations come through the Mac: keep Stow there signed in to YouTube. Until then, here's what's new from your channels.")
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }
        ForEach(videos) { VideoCard(item: $0, actions: actions) }
        Text(videos.isEmpty ? "Nothing here yet. Pull down to ask the Mac for videos." : "That's everything for now. Pull up for a fresh batch.")
            .font(.footnote)
            .foregroundStyle(colors.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
    }

    /// Which banners are up on top of the feed.
    private struct BannerKey: Equatable {
        var updates, expired, signIn: Bool
    }

    @ViewBuilder private func groupFeed(_ group: ChannelGroup, videos: [VideoItem], actions: VideoActions) -> some View {
        if group.channels.isEmpty {
            EmptyState("“\(group.name)” has no channels yet.")
            Button("Add channels") { shell.open(.group(group.id)) }
                .font(.body.weight(.medium))
        } else {
            let watched = videos.filter(\.watched)
            ForEach(videos.filter { !$0.watched }) { VideoCard(item: $0, actions: actions) }
            CaughtUp(what: "That's everything new from \(group.name).", watchedCount: watched.count, showingWatched: showWatched) {
                withAnimation(Motion.standard) { showWatched.toggle() }
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

/// Standalone: the one-line banner after YouTube signed the phone out, and (after switching from
/// the Mac) the card suggesting a sign-in here.
private struct StandaloneBanners: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors

    var body: some View {
        if repository.mode == .standalone, let standalone = repository.standalone {
            if standalone.showsExpiredBanner {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(colors.destructive)
                    Text("YouTube signed you out.")
                        .font(.subheadline)
                        .foregroundStyle(colors.text)
                    Spacer(minLength: 4)
                    Button("Sign in") { shell.signingIn = true }
                        .font(.subheadline.weight(.semibold))
                    Button("Close", systemImage: "xmark") { withAnimation(Motion.standard) { standalone.closeExpiredBanner() } }
                        .labelStyle(.iconOnly)
                        .font(.subheadline)
                        .foregroundStyle(colors.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(colors.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .motionTransition(.opacity.combined(with: .move(edge: .top)))
            } else if standalone.showsSignInPrompt {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sign in to YouTube on this phone for Home, Subscriptions and members-only videos.")
                        .font(.subheadline)
                        .foregroundStyle(colors.text)
                    HStack(spacing: 10) {
                        PillButton(label: "Sign in", filled: true) { shell.signingIn = true }
                        PillButton(label: "Not now") { withAnimation(Motion.standard) { standalone.closeSignInPrompt() } }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .motionTransition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Standalone with nothing followed: what to do first.
private struct StandaloneEmptyHome: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(colors.secondaryText)
                .accessibilityHidden(true)
            Text("Follow channels to see their new videos here")
                .font(.title3.weight(.semibold))
                .foregroundStyle(colors.text)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                PillButton(label: "Add a channel", systemImage: "plus", filled: true) { shell.addingChannel = true }
                if repository.standalone?.isSignedIn == true {
                    PillButton(label: "Import from YouTube", systemImage: "square.and.arrow.down") { shell.open(.importChannels) }
                }
                PillButton(label: "Search YouTube", systemImage: "magnifyingglass") { shell.open(.search) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }
}
