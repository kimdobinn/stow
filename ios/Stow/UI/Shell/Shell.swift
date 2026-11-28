import Observation
import StowKit
import SwiftUI

/// The app's tabs.
enum AppTab: Hashable {
    case home, subscriptions, downloads
}

/// Screens pushed on a tab's navigation stack (Android MainActivity's routes).
enum Route: Hashable {
    /// A channel's page (UI/Channel).
    case channel(String)
    /// Every channel you follow ("All" on Subscriptions).
    case channels
    /// Settings › Channel groups.
    case groups
    /// One group, to rename, fill or delete.
    case group(String)
    /// A playlist (UI/Library).
    case playlist(String)
    /// Search all of YouTube (UI/Search).
    case search
    case settings
    /// Your week: time watched (UI/Settings).
    case report
    /// The yt-dlp self-test, for checking a build.
    case ytdlp
    /// Standalone: the YouTube sign-in (UI/Account).
    case account
    /// Standalone: the followed channels, to order and remove (UI/Channels).
    case channelsManage
    /// Standalone: pick channels from the account's YouTube subscriptions.
    case importChannels
}

/// What to play: a video and the list it plays within (the rest is up next).
struct PlaybackRequest: Identifiable, Equatable {
    let id = UUID()
    /// Video ids in order, the started one among them.
    var queue: [String]
    var startId: String
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
}

/// The app's navigation and the things any screen can ask of it: open a route, play a video,
/// show a short message, and the sheets and dialogs that belong to no one screen (add a channel
/// to a group, new group, a long download's size, save to playlist).
@MainActor
@Observable
final class Shell {
    let repository: Repository

    var tab: AppTab = .home
    var homePath: [Route] = []
    var subscriptionsPath: [Route] = []
    var downloadsPath: [Route] = []

    /// What the player was asked to play (it plays within the queue from there); nil when the
    /// player is closed. Setting it plays; setting nil closes the player.
    var playback: PlaybackRequest?
    /// The watch page is open; otherwise the mini player shows above the tabs (while `playback` is set).
    var playerExpanded = false
    private(set) var toast: Toast?

    /// "Add channel to a group" is open for this channel.
    var grouping: GroupChannel?
    /// "New group" is asking for a name.
    var namingNewGroup = false
    /// A long video's size is shown before it downloads.
    var sizing: VideoItem?
    /// "Save to playlist" is open for this video.
    var saving: VideoItem?
    /// The update sheet (release notes, "Update in SideStore") is open for this release.
    var update: AppUpdate?
    /// Standalone: the web login to YouTube is open.
    var signingIn = false
    /// Standalone: the cookies.txt picker is open.
    var importingCookies = false
    /// Standalone: "Add a channel" (URL, @handle or channel ID) is open.
    var addingChannel = false
    /// Standalone: a stow://pair link waits for "Pair with this Mac?".
    var pairingLink: String?

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(repository: Repository) {
        self.repository = repository
    }

    // Navigation

    /// Pushes a screen on the current tab.
    func open(_ route: Route) {
        switch tab {
        case .home: homePath.append(route)
        case .subscriptions: subscriptionsPath.append(route)
        case .downloads: downloadsPath.append(route)
        }
    }

    func back() {
        switch tab {
        case .home: _ = homePath.popLast()
        case .subscriptions: _ = subscriptionsPath.popLast()
        case .downloads: _ = downloadsPath.popLast()
        }
    }

    /// Tapping the tab you're on goes back to its first screen.
    func select(_ newTab: AppTab) {
        if newTab == tab {
            switch tab {
            case .home: homePath = []
            case .subscriptions: subscriptionsPath = []
            case .downloads: downloadsPath = []
            }
        }
        tab = newTab
    }

    /// Opens a channel's page; from the watch page, it shrinks into the mini player first, like YouTube.
    func openChannel(_ id: String) {
        guard !id.isEmpty else { return }
        playerExpanded = false
        open(.channel(id))
    }

    /// Stops playing and closes the player.
    func closePlayer() {
        playback = nil
        playerExpanded = false
    }

    /// The app's player (AppServices connects it).
    @ObservationIgnored weak var player: PlaybackController?

    // Messages

    func notify(_ message: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = Toast(message: message) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { self?.toast = nil }
        }
    }

    // Playing

    /// Plays within the list you're looking at: under Downloads every download in its order,
    /// elsewhere every downloaded video, newest first. A video that isn't downloaded streams on its own.
    func play(_ item: VideoItem) {
        let context: [VideoItem]
        if !item.isPlayable {
            context = [item]
        } else if tab == .downloads {
            context = Feeds.sorted(repository.downloadItems.filter(\.isPlayable), by: repository.prefs.downloadSort)
        } else {
            context = repository.feed.filter(\.isPlayable)
        }
        // A download only in YouTube's feeds isn't in those lists: it plays first, then the rest, as on Android.
        play(context.contains { $0.id == item.id } ? context : [item] + context, start: item)
    }

    /// Plays `item` with `list` as the queue (the item is added when it isn't in it).
    func play(_ list: [VideoItem], start item: VideoItem) {
        var ids = list.map(\.id)
        if !ids.contains(item.id) { ids = [item.id] }
        playback = PlaybackRequest(queue: ids, startId: item.id)
        playerExpanded = true
    }

    // Actions

    /// The app's video actions (see `VideoActions`).
    var actions: VideoActions {
        VideoActions(
            play: { [weak self] in self?.play($0) },
            download: { [weak self] in self?.download($0) },
            delete: { [weak self] in self?.delete($0) },
            setWatched: { [weak self] item, watched in
                self?.repository.setWatched(item.id, watched)
                self?.notify(watched ? "Marked as watched" : "Marked as unwatched")
            },
            saveToPlaylist: { [weak self] in self?.saving = $0 },
            openChannel: { [weak self] in self?.openChannel($0) },
            notify: { [weak self] in self?.notify($0) },
            addToGroup: { [weak self] item in
                self?.grouping = GroupChannel(id: item.video.channelId, title: item.video.channelTitle)
            },
            follow: repository.mode == .standalone ? { [weak self] item in self?.follow(item.video.channelId, title: item.video.channelTitle) } : nil,
            isFollowing: { [weak self] in self?.repository.followedIds.contains($0) ?? false },
            marksAnyWatched: repository.mode == .standalone
        )
    }

    /// Standalone: follows a channel (from a video's menu or its page) and checks it.
    func follow(_ channelId: String, title: String, avatarURL: String? = nil) {
        guard !channelId.isEmpty, let standalone = repository.standalone else { return }
        if standalone.follow(ChannelInfo(id: channelId, title: title, avatarURL: avatarURL)) {
            notify("Following \(title)")
        }
    }

    /// Standalone: unfollows (downloads stay).
    func unfollow(_ channelId: String) {
        guard let standalone = repository.standalone else { return }
        let title = standalone.channels.first { $0.id == channelId }?.title ?? repository.channelTitle(channelId)
        standalone.unfollow(channelId)
        notify("Removed \(title)")
    }

    /// Long videos (past streams especially) can be gigabytes: their size is shown first.
    func download(_ item: VideoItem) {
        if item.durationMs >= Repository.longVideoMs && item.state != .failed {
            sizing = item
        } else {
            let retrying = item.state == .failed
            repository.download(item)
            notify(retrying ? "Retrying download" : "Downloading")
        }
    }

    func delete(_ item: VideoItem) {
        if playback != nil, player?.currentId == item.id { closePlayer() }
        repository.deleteDownload(item.id)
        notify(item.isPlayable ? "Deleted from downloads" : "Download canceled")
    }

    /// Pull to refresh: with the Mac, asks it to check every channel and YouTube's feeds now and
    /// waits for it; on its own, the phone checks them.
    func refresh() async {
        notify(Self.refreshMessage(await repository.pullToRefresh(), mode: repository.mode))
    }

    static func refreshMessage(_ result: RefreshResult, mode: AppMode) -> String {
        switch result {
        case .done: "Up to date"
        case .noAnswer: "The Mac didn't answer. Is Stow running on it?"
        case .failed: mode == .standalone ? "Couldn't reach YouTube. Check the connection." : "Couldn't reach the Mac's Firebase. Check the connection."
        case .youtubeFailed: "Couldn't reach YouTube. Check the connection."
        case .slowedDown: "YouTube asked Stow to slow down. It'll try again later."
        }
    }

    // Groups

    var groupActions: GroupActions {
        GroupActions(repository: repository, notify: { [weak self] in self?.notify($0) })
    }
}

/// What the group screens can do (the Repository's group functions).
/// In standalone mode a group holds only followed channels: adding one that isn't followed
/// follows it ("Following … too"), as the Mac does.
@MainActor
struct GroupActions {
    let repository: Repository
    var notify: (String) -> Void = { _ in }

    @discardableResult
    func create(_ name: String, with channel: GroupChannel? = nil) -> ChannelGroup {
        let (group, followed) = repository.createGroupFollowing(name, with: channel)
        if followed, let channel { notify("Added to \(group.name). Following \(channel.title) too") }
        return group
    }
    func rename(_ id: String, to name: String) { repository.renameGroup(id, to: name) }
    func delete(_ id: String) { repository.deleteGroup(id) }
    /// True when the phone started following the channel (the caller's toast says so).
    @discardableResult
    func set(_ groupId: String, channel: GroupChannel, included: Bool) -> Bool {
        repository.setInGroup(groupId, channel: channel, included: included)
    }
    func move(_ id: String, by offset: Int) { repository.moveGroup(id, by: offset) }
}
