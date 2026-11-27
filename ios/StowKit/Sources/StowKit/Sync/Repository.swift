import Foundation
import Observation
import os

/// The app's state: pairing, the Mac's channels and sent videos, YouTube's feeds, searches and
/// channel pages, and what this phone downloaded. Views read it directly (it's @Observable).
///
/// With no push on a sideloaded iPhone, it polls Firestore: call `start()` once at launch,
/// `setActive(_:)` as the scene becomes active or leaves the screen (it polls on activation and
/// every 60 s while active), `refreshFromMac()` for pull-to-refresh, and `backgroundRefresh()`
/// from a BGAppRefreshTask.
@MainActor
@Observable
public final class Repository {
    public let prefs: Prefs
    public let local: LocalStore
    public let playlistStore: PlaylistStore
    public let stats: WatchStats
    public let downloads: DownloadManager
    /// nil in demo mode or when the build has no Firebase settings.
    @ObservationIgnored public let remote: Remote?
    @ObservationIgnored public let youtube: YouTubeTool
    public let isDemo: Bool
    /// Shown on the Mac's list of phones. The app sets it (UIDevice's name).
    @ObservationIgnored public var deviceName = "iPhone"

    public private(set) var pairState: PairState
    /// In the Mac's order.
    public private(set) var channels: [Channel] = []
    /// YouTube's own Home and Subscriptions, shared by the Mac.
    public private(set) var youtubeFeeds = YouTubeFeeds()
    public private(set) var shared = SharedState()
    /// Every known video (sent to the phone, recent on a channel, in YouTube's feeds or found by a
    /// search or channel page), by id. No Shorts unless downloaded.
    public private(set) var items: [String: VideoItem] = [:]
    /// `items`' ids in the order they were first seen (YouTube's feeds first).
    public private(set) var itemOrder: [String] = []
    /// Channel pages loaded on the phone (this run of the app), by channel id.
    public private(set) var channelPages: [String: ChannelPage] = [:]
    /// When the last poll of Firebase succeeded.
    public private(set) var lastSync: Date?
    /// Why the last poll failed, when it did (cleared by the next good one).
    public private(set) var syncError: String?

    @ObservationIgnored private var sent: [SentVideo] = []
    @ObservationIgnored private var serverSent: [SentVideo] = []
    @ObservationIgnored private var searchedOrder: [String] = []
    @ObservationIgnored private var searched: [String: Video] = [:]
    /// Writes not seen in a poll yet, so the screen doesn't flip back meanwhile.
    @ObservationIgnored private var pendingWatched: [String: (watched: Bool, at: Date)] = [:]
    /// This phone's download requests being filed right now (see `sendPendingRequests`).
    @ObservationIgnored private var requestsInFlight: Set<String> = []
    @ObservationIgnored private var groupEditsInFlight = 0
    @ObservationIgnored private var lastSealedFeeds: String?
    @ObservationIgnored private var videoCursor: String?
    @ObservationIgnored private var channelCursor: String?
    @ObservationIgnored private var lastFullSync: Date?
    @ObservationIgnored private var polling: Task<Bool, Never>?
    @ObservationIgnored private var pollLoop: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var signingOut: Task<Void, Never>?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let log = Logger(subsystem: "dev.stow.ios", category: "repository")

    /// How often to poll while the app is on screen.
    @ObservationIgnored public var pollInterval: Duration = .seconds(60)

    public static let refreshTimeout: Duration = .seconds(120)
    public static let searchResults = 40
    public static let searchKeep = 400
    public static let channelPageVideos = 30
    public static let channelPageStreams = 15
    public static let channelPageFresh: TimeInterval = 30 * 60
    /// Downloads longer than this ask first, with the size.
    public static let longVideoMs = 20 * 60 * 1000
    static let pendingTimeout: TimeInterval = 120
    /// How often a poll reads every document instead of the changes (deletions show only then).
    static let fullSyncInterval: TimeInterval = 15 * 60

    /// - Parameters:
    ///   - config: the Firebase project (nil when the build has none; pairing then says so).
    ///   - directory: Application Support (a temporary folder in tests).
    ///   - session: for Firebase (tests pass one with a stub URLProtocol).
    public init(config: FirebaseConfig?, youtube: YouTubeTool, demo: Bool = false,
                defaults: UserDefaults = .standard, directory: URL = StowPaths.applicationSupport,
                tokenStore: TokenStore = KeychainTokenStore(), network: NetworkMonitoring? = nil,
                session: URLSession? = nil) {
        let prefs = Prefs(defaults: defaults)
        let local = LocalStore(directory: directory)
        self.prefs = prefs
        self.local = local
        self.directory = directory
        playlistStore = PlaylistStore(directory: directory)
        stats = WatchStats(directory: directory)
        downloads = DownloadManager(local: local, prefs: prefs, network: network ?? PathMonitor(), tool: youtube, directory: directory)
        self.youtube = youtube
        isDemo = demo
        remote = demo ? nil : config.map { Remote(config: $0, session: session, tokenStore: tokenStore) }
        if demo {
            pairState = .paired
        } else if let config, prefs.pairedProject == config.projectId, tokenStore.load() != nil {
            pairState = .paired
        } else {
            pairState = .unpaired(message: nil)
        }
        downloads.host = self
        local.onChange = { [weak self] in self?.rebuildItems() }
    }

    /// The app's repository: Firebase.plist from the app bundle, tokens in the Keychain, demo mode
    /// from the `-demo` argument or a "demo" file in Application Support.
    public static func live(youtube: YouTubeTool) -> Repository {
        Repository(config: FirebaseConfig.load(), youtube: youtube, demo: Demo.isEnabled())
    }

    public var isPaired: Bool { pairState == .paired }

    /// Once, at launch: picks up the download queue and, in demo mode, fills in the samples.
    public func start() {
        guard !started else { return }
        started = true
        if isDemo {
            channels = DemoData.channels()
            youtubeFeeds = DemoData.youtubeFeeds()
            rebuildItems()
            onSentVideos(DemoData.sent())
        } else {
            // Downloads (and requests not filed yet) show before the first poll answers.
            rebuildItems()
        }
        downloads.restore()
    }

    public func item(_ id: String) -> VideoItem? { items[id] }
    public func channel(_ id: String) -> Channel? { channels.first { $0.id == id } }
    public var groups: [ChannelGroup] { shared.groups }
    public var playlists: [Playlist] { playlistStore.playlists }

    // Lists the screens show (as the Android app's MainActivity builds them)

    /// Everything but videos only in YouTube's feeds or searches, newest first.
    public var feed: [VideoItem] { Feeds.newestFirst(orderedItems.filter { !$0.onlyInYouTubeFeeds }) }

    /// Everything but search and channel-page results, newest first (Home's channel groups, search's "in your videos").
    public var everything: [VideoItem] { Feeds.newestFirst(orderedItems.filter { !$0.fromSearch }) }

    /// YouTube's Home recommendations, in YouTube's order.
    public var recommended: [VideoItem] { youtubeFeeds.recommended.compactMap { items[$0.id] } }

    /// YouTube's Subscriptions feed with the Mac's channels' videos slotted in by date.
    public var subscriptionsFeed: [VideoItem] {
        Feeds.subscriptions(feed: youtubeFeeds.subscriptions.compactMap { items[$0.id] }, channelVideos: feed)
    }

    /// Videos downloaded, downloading or waiting, in no particular order.
    public var downloadItems: [VideoItem] {
        orderedItems.filter { $0.state == .queued || $0.state == .downloading || $0.state == .downloaded }
    }

    /// The Mac's channels first (with their pictures), then the rest YouTube's feeds mention.
    public var knownChannels: [KnownChannel] {
        var seen = Set<String>()
        let fromMac = channels.map { KnownChannel(id: $0.id, title: $0.title, avatarURL: $0.avatarURL) }
        let fromFeeds = (youtubeFeeds.subscriptions + youtubeFeeds.recommended).filter { !$0.channelId.isEmpty }
            .map { KnownChannel(id: $0.channelId, title: $0.channelTitle, avatarURL: youtubeFeeds.channelAvatars[$0.channelId]) }
        return (fromMac + fromFeeds).filter { seen.insert($0.id).inserted }
    }

    /// Channels you follow: on the Mac, or in YouTube's Subscriptions feed.
    public var subscribedChannels: [KnownChannel] {
        let ids = Set(channels.map(\.id)).union(youtubeFeeds.subscriptions.map(\.channelId))
        return knownChannels.filter { ids.contains($0.id) }
    }

    /// Channel pictures by id: the Mac's channels' first, then the ones it looked up for YouTube's
    /// feeds, then channel pages loaded here.
    public var avatars: [String: String] {
        var result: [String: String] = [:]
        for (id, page) in channelPages { if let url = page.avatarURL { result[id] = url } }
        for (id, url) in youtubeFeeds.channelAvatars { result[id] = url }
        for channel in channels { if let url = channel.avatarURL { result[channel.id] = url } }
        return result
    }

    /// A channel's videos: its latest from YouTube (when loaded here) in YouTube's order, then the
    /// rest you know of, newest first.
    public func channelVideos(_ channelId: String) -> [VideoItem] {
        let known = everything.filter { $0.video.channelId == channelId }
            + orderedItems.filter { $0.fromSearch && $0.video.channelId == channelId }
        let loaded = channelPages[channelId].map { ($0.videoIds + $0.streamIds).compactMap { items[$0] } } ?? []
        let loadedIds = Set(loaded.map(\.id))
        return loaded + known.filter { !loadedIds.contains($0.id) }
    }

    /// The channel's name, from whatever knows it.
    public func channelTitle(_ channelId: String) -> String {
        channel(channelId)?.title ?? knownChannels.first { $0.id == channelId }?.title
            ?? channelPages[channelId]?.title.nilIfEmpty ?? channelVideos(channelId).first?.video.channelTitle ?? ""
    }

    public func groupVideos(_ group: ChannelGroup) -> [VideoItem] { Feeds.group(group, all: everything) }

    private var orderedItems: [VideoItem] { itemOrder.compactMap { items[$0] } }

    // Pairing

    /// Pairs with the Mac from the QR code's text (stow://pair?…); returns when it's done or failed
    /// (see `pairState`).
    public func pair(_ qrText: String) async {
        guard let invite = Invite.parse(qrText) else {
            pairState = .unpaired(message: "That isn't a Stow pairing code. Open Stow › Phone › Pair a Phone on the Mac.")
            return
        }
        guard pairState != .pairing else { return }
        guard let remote else {
            pairState = .unpaired(message: StowError.notConfigured.message)
            return
        }
        pairState = .pairing
        // A pairing right after unpairing must not reuse the old user.
        await signingOut?.value
        signingOut = nil
        do {
            try await remote.pair(invite, deviceName: deviceName)
            prefs.savePairing(projectId: invite.projectId, keyBase64URL: invite.key)
            pairState = .paired
            _ = await refresh()
        } catch {
            log.warning("Pairing failed: \(String(describing: error), privacy: .public)")
            pairState = .unpaired(message: (error as? LocalizedError)?.errorDescription ?? "Pairing failed.")
        }
    }

    /// Forgets the pairing on this phone. Downloads stay until deleted.
    public func unpair(message: String? = nil) {
        prefs.clearPairing()
        if let remote { signingOut = Task { await remote.signOut() } }
        sent = []
        serverSent = []
        pendingWatched = [:]
        // Requests not filed yet would go to whichever Mac pairs next; the downloads stay listed.
        for video in local.videos.values where video.requestedAt != nil {
            local.update(video.id) { $0.map { var video = $0; video.requestedAt = nil; return video } }
        }
        channels = []
        youtubeFeeds = YouTubeFeeds()
        lastSealedFeeds = nil
        videoCursor = nil
        channelCursor = nil
        lastFullSync = nil
        shared = SharedState()
        lastSync = nil
        syncError = nil
        pairState = .unpaired(message: message)
        rebuildItems()
    }

    // Polling

    /// The scene became active (poll now, then every minute) or left the screen (stop).
    public func setActive(_ active: Bool) {
        pollLoop?.cancel()
        pollLoop = nil
        guard active else {
            stats.flush()
            return
        }
        downloads.reevaluate()
        pollLoop = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.refresh()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// For a BGAppRefreshTask: one poll (new videos join the download queue). True when it worked.
    public func backgroundRefresh() async -> Bool {
        await refresh()
    }

    /// Reads Firebase once: what changed since the last poll, or everything when `full` (and on
    /// the first poll and every 15 minutes, which is how deleted channels and videos go). A poll
    /// already under way is joined, not repeated. True when it worked.
    @discardableResult
    public func refresh(full: Bool = false) async -> Bool {
        guard !isDemo, isPaired, let remote else { return isDemo }
        if let polling { return await polling.value }
        let task = Task { await self.poll(remote, full: full) }
        polling = task
        defer { polling = nil }
        return await task.value
    }

    private func poll(_ remote: Remote, full forced: Bool) async -> Bool {
        let full = forced || lastFullSync.map { Date.now.timeIntervalSince($0) > Self.fullSyncInterval } ?? true
        let videoCursor = full ? nil : videoCursor
        let channelCursor = full ? nil : channelCursor
        async let videosResult = Self.result { try await remote.videoChanges(after: videoCursor) }
        async let channelsResult = Self.result { try await remote.channelChanges(after: channelCursor) }
        async let feedsResult = Self.result { try await remote.sealedAccountFeeds() }
        async let sharedResult = Self.result { try await remote.shared() }
        let (videos, channels, feeds, shared) = await (videosResult, channelsResult, feedsResult, sharedResult)
        // Unpaired (or signed out) while this ran.
        guard isPaired else { return false }

        var failure: Error?
        switch channels {
        case .success(let changes):
            self.channels = (full ? changes.values : Self.merged(self.channels, changes.values, id: \.id)).sorted { $0.order < $1.order }
            self.channelCursor = changes.cursor
        case .failure(let error): failure = error
        }
        if case .success(let sealed) = feeds { openFeeds(sealed) } else if case .failure(let error) = feeds { failure = failure ?? error }
        if case .success(let value) = shared { applyShared(value) } else if case .failure(let error) = shared { failure = failure ?? error }
        switch videos {
        case .success(let changes):
            self.videoCursor = changes.cursor
            onSentVideos(full ? changes.values : Self.merged(serverSent, changes.values, id: \.video.id))
        case .failure(let error): failure = failure ?? error
        }
        rebuildItems()

        guard let failure else {
            lastSync = .now
            if full { lastFullSync = .now }
            syncError = nil
            return true
        }
        if failure as? StowError == .notPaired {
            // A read can be refused briefly; ask the server before giving up.
            let member = (try? await remote.isMember()) ?? true
            if !member, isPaired { unpair(message: "The Mac unpaired this phone.") }
        } else if !(failure is CancellationError) {
            log.warning("Sync failed: \(String(describing: failure), privacy: .public)")
            syncError = (failure as? LocalizedError)?.errorDescription ?? "Couldn't reach the Mac's Firebase."
        }
        return false
    }

    /// `old` with `changes` applied: changed ones replaced where they were, new ones at the end.
    static func merged<T>(_ old: [T], _ changes: [T], id: (T) -> String) -> [T] {
        var result = old
        var index = Dictionary(old.enumerated().map { (id($1), $0) }, uniquingKeysWith: { first, _ in first })
        for value in changes {
            if let at = index[id(value)] {
                result[at] = value
            } else {
                index[id(value)] = result.count
                result.append(value)
            }
        }
        return result
    }

    nonisolated private static func result<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private func openFeeds(_ sealed: String?) {
        guard sealed != lastSealedFeeds || youtubeFeeds.isEmpty else { return }
        lastSealedFeeds = sealed
        guard let sealed, let key = prefs.pairingKey else {
            youtubeFeeds = YouTubeFeeds()
            return
        }
        do {
            youtubeFeeds = try YouTubeFeeds.parse(Crypto.open(base64: sealed, key: key))
        } catch {
            log.warning("Couldn't open YouTube's feeds: \(String(describing: error), privacy: .public)")
            youtubeFeeds = YouTubeFeeds()
        }
    }

    private func applyShared(_ value: SharedState) {
        var value = value
        // Our own edit is on its way: keep it until the server has it.
        if groupEditsInFlight > 0 { value.groups = shared.groups }
        shared = value
    }

    /// The Mac's videos/: new ones get downloaded; ones sent again after a failure or delete are retried.
    func onSentVideos(_ videos: [SentVideo]) {
        serverSent = videos
        let now = Date.now
        pendingWatched = pendingWatched.filter { id, pending in
            let server = videos.first { $0.video.id == id }?.watched
            return server != pending.watched && now.timeIntervalSince(pending.at) < Self.pendingTimeout
        }
        // This phone's own requests, now on the server: the server's sentAt (its commit time,
        // a little after the tap) replaces the tap's, or the deleted download would look sent again.
        for video in videos {
            guard local[video.video.id]?.requestedAt != nil else { continue }
            local.update(video.video.id) { $0.map { existing in
                var existing = existing
                existing.requestedAt = nil
                if let sentAt = video.sentAt { existing.sentAt = sentAt }
                return existing
            } }
        }
        rebuildItems()
        for video in sent {
            let id = video.video.id
            let sentAt = video.sentAt ?? Date(timeIntervalSince1970: 0)
            guard let existing = local[id] else {
                queue(id, sentAt: sentAt, video: video.video)
                continue
            }
            if existing.video == nil {
                local.update(id) { $0.map { var known = $0; known.video = video.video; return known } }
            }
            switch existing.state {
            case .failed, .deleted:
                if sentAt > existing.sentAt { queue(id, sentAt: sentAt, video: video.video) }
            case .queued, .downloading:
                downloads.enqueue(id)
            case .downloaded:
                if local.fileURL(for: id) == nil { queue(id, sentAt: sentAt, video: video.video) }
            }
        }
        rebuildItems()
        sendPendingRequests()
    }

    /// What the server sent, with watched changes on their way, then this phone's requests the
    /// server doesn't have yet (in demo mode, every request: there's no server).
    private func effectiveSent() -> [SentVideo] {
        var result = serverSent.map { video -> SentVideo in
            guard let pending = pendingWatched[video.video.id] else { return video }
            var video = video
            video.watched = pending.watched
            return video
        }
        let onServer = Set(serverSent.map(\.video.id))
        result += local.videos.values
            .filter { $0.requestedAt != nil && $0.state != .deleted && !onServer.contains($0.id) }
            .sorted { ($0.requestedAt ?? .distantPast, $0.id) < ($1.requestedAt ?? .distantPast, $1.id) }
            .compactMap { local in
                local.video.map { SentVideo(video: $0, sentAt: local.sentAt, sentBy: "phone", watched: prefs.watchedHere.contains(local.id)) }
            }
        return result
    }

    /// A request of this phone's that the server doesn't have yet (its watched state lives here).
    private func isUnfiledRequest(_ id: String) -> Bool {
        local[id]?.requestedAt != nil && !serverSent.contains { $0.video.id == id }
    }

    /// Files this phone's download requests the server doesn't have yet. A failed one (no
    /// connection, Firestore's quota, a 5xx) is tried again on the next poll, like the SDK's
    /// offline queue on Android. Until it's filed the video shows as sent from here.
    private func sendPendingRequests() {
        guard !isDemo, isPaired, let remote else { return }
        let onServer = Set(serverSent.map(\.video.id))
        let waiting = local.videos.values.filter { video in
            video.requestedAt != nil && video.state != .deleted && video.video != nil
                && !onServer.contains(video.id) && !requestsInFlight.contains(video.id)
        }
        for request in waiting.sorted(by: { $0.id < $1.id }) {
            guard let video = request.video else { continue }
            let id = request.id
            let watched = prefs.watchedHere.contains(id)
            requestsInFlight.insert(id)
            Task {
                defer { requestsInFlight.remove(id) }
                do {
                    if let sentAt = try await remote.requestDownload(video, watched: watched) {
                        confirmRequest(SentVideo(video: video, sentAt: sentAt, sentBy: "phone", watched: watched))
                    } else if let filed = try? await remote.video(id) {
                        // No server time in the answer; the phone's clock won't do (see onSentVideos).
                        confirmRequest(filed)
                    }
                } catch StowError.notPaired {
                    // Refused: the video most likely has a document already (the Mac or another
                    // phone sent it meanwhile), which a phone may not overwrite. Take that one.
                    // If the Mac unpaired this phone instead, the next poll finds out.
                    if let existing = try? await remote.video(id) {
                        confirmRequest(existing)
                    } else {
                        log.warning("requestDownload for \(id, privacy: .public) refused")
                    }
                } catch {
                    log.warning("requestDownload failed, trying again on the next poll: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func confirmRequest(_ video: SentVideo) {
        guard isPaired else { return }
        let id = video.video.id
        let watchedHere = prefs.watchedHere.contains(id)
        onSentVideos(Self.merged(serverSent, [video], id: \.video.id))
        // Marked (un)watched while the request was on its way.
        if watchedHere != video.watched { pushWatched(id, watchedHere) }
    }

    func rebuildItems() {
        sent = effectiveSent()
        let merged = Self.mergeItems(sent: sent, channels: channels, local: local.videos, watchedHere: prefs.watchedHere,
                                     feeds: youtubeFeeds, searched: searchedOrder.compactMap { searched[$0] })
        if merged.items != items { items = merged.items }
        if merged.order != itemOrder { itemOrder = merged.order }
    }

    /// The merge behind `items`, as on Android: YouTube's feeds, then searches, then the Mac's
    /// channels, then what was sent (each later source wins for a video they share).
    static func mergeItems(sent: [SentVideo], channels: [Channel], local: [String: LocalVideo], watchedHere: Set<String>,
                           feeds: YouTubeFeeds, searched: [Video]) -> (order: [String], items: [String: VideoItem]) {
        var result: [String: VideoItem] = [:]
        var order: [String] = []
        func put(_ item: VideoItem) {
            if result[item.id] == nil { order.append(item.id) }
            result[item.id] = item
        }
        for video in feeds.recommended + feeds.subscriptions where result[video.id] == nil {
            put(VideoItem(video: video, sent: nil, local: local[video.id], watchedOnMac: watchedHere.contains(video.id), onlyInYouTubeFeeds: true))
        }
        for video in searched where result[video.id] == nil {
            put(VideoItem(video: video, sent: nil, local: local[video.id], watchedOnMac: watchedHere.contains(video.id),
                          onlyInYouTubeFeeds: true, fromSearch: true))
        }
        // YouTube's feeds know the length of videos the Mac's channel list doesn't.
        func withFeedDuration(_ video: Video) -> Video {
            guard video.durationSeconds == nil else { return video }
            var video = video
            video.durationSeconds = result[video.id]?.video.durationSeconds
            return video
        }
        for channel in channels {
            for recent in channel.recent {
                put(VideoItem(video: withFeedDuration(recent.video), sent: nil, local: local[recent.video.id],
                              watchedOnMac: recent.watched || watchedHere.contains(recent.video.id)))
            }
        }
        for video in sent {
            let watchedOnMac = result[video.video.id]?.watchedOnMac ?? false
            put(VideoItem(video: withFeedDuration(video.video), sent: video, local: local[video.video.id], watchedOnMac: watchedOnMac))
        }
        // Downloads nothing else mentions any more (the search they came from is gone, say) stay
        // listed, so they can still be played and deleted.
        for video in local.values.sorted(by: { $0.id < $1.id }) where result[video.id] == nil && video.state != .deleted {
            guard let known = video.video else { continue }
            put(VideoItem(video: known, sent: nil, local: video, watchedOnMac: watchedHere.contains(video.id),
                          onlyInYouTubeFeeds: true, fromSearch: true))
        }
        for (id, item) in result where item.video.isShort && item.local?.state != .downloaded {
            result[id] = nil
        }
        return (order.filter { result[$0] != nil }, result)
    }

    // Pull to refresh

    /// Asks the Mac to check every channel and YouTube's feeds now, and waits for it (up to 2 minutes).
    public func refreshFromMac() async -> RefreshResult {
        if isDemo {
            try? await Task.sleep(for: .milliseconds(800))
            return .done
        }
        guard let remote, isPaired else { return .failed }
        _ = await refresh()
        let requested: Date
        do {
            requested = try await remote.requestRefresh()
        } catch {
            log.warning("Refresh request failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.refreshTimeout)
        while clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard let state = try? await remote.shared() else { continue }
            applyShared(state)
            // The Mac answers with the request's time (to the millisecond).
            if let handled = state.refreshHandledAt, handled >= requested.addingTimeInterval(-1) {
                _ = await refresh(full: true)
                return .done
            }
        }
        return .noAnswer
    }

    // YouTube on the phone

    /// Searches all of YouTube; the results join `items` (so they play and download like any
    /// video). Returns their ids in YouTube's order.
    public func searchYouTube(_ query: String) async throws -> [String] {
        let json = try await youtube.search(query, count: Self.searchResults)
        let videos = try YouTubeListing.parse(json)
        prefs.addRecentSearch(query)
        addFound(videos)
        return videos.map(\.id)
    }

    /// Loads a channel's latest uploads and past streams from YouTube; they join `items` like
    /// search results. Skipped when loaded in the last half hour.
    public func loadChannelPage(_ channelId: String) async throws {
        if let known = channelPages[channelId], Date.now.timeIntervalSince(known.loadedAt) < Self.channelPageFresh { return }
        let youtube = youtube
        async let uploadsJSON = youtube.channelTab(channelId: channelId, tab: .videos, count: Self.channelPageVideos)
        async let streamsJSON = try? youtube.channelTab(channelId: channelId, tab: .streams, count: Self.channelPageStreams)
        let (uploadsText, streamsText) = try await (uploadsJSON, streamsJSON)
        let uploads = try YouTubeListing.parse(uploadsText)
        let streams = (streamsText.flatMap { try? YouTubeListing.parse($0) } ?? []).filter(\.isPastStream)
        addFound(uploads + streams)
        channelPages[channelId] = ChannelPage(title: YouTubeListing.channelTitle(uploadsText) ?? "",
                                              avatarURL: YouTubeListing.channelAvatar(uploadsText),
                                              videoIds: uploads.map(\.id), streamIds: streams.map(\.id), loadedAt: .now)
    }

    /// Videos from searches and channel pages, for `items`.
    private func addFound(_ videos: [Video]) {
        for video in videos {
            searchedOrder.removeAll { $0 == video.id }
            searchedOrder.append(video.id)
            searched[video.id] = video
        }
        // Keep the latest few lists' videos, not every one since the app started.
        if searchedOrder.count > Self.searchKeep {
            for id in searchedOrder.prefix(searchedOrder.count - Self.searchKeep) { searched[id] = nil }
            searchedOrder.removeFirst(searchedOrder.count - Self.searchKeep)
        }
        rebuildItems()
    }

    /// Where to stream a video that isn't downloaded.
    public func stream(_ video: Video) async throws -> StreamInfo {
        let cookies = video.isMembersOnly ? await cookiesFile() : nil
        defer { if let cookies { try? FileManager.default.removeItem(at: cookies) } }
        return try await youtube.stream(video, cookies: cookies)
    }

    /// The downloaded file to play, when there is one.
    public func fileURL(for id: String) -> URL? { local.fileURL(for: id) }

    /// What downloading would take, in bytes (yt-dlp's figure, else an estimate from the length).
    public func downloadSize(_ item: VideoItem) async -> Int64? {
        let cookies = item.video.isMembersOnly ? await cookiesFile() : nil
        defer { if let cookies { try? FileManager.default.removeItem(at: cookies) } }
        if let size = try? await youtube.downloadSize(item.video, cookies: cookies, quality: prefs.downloadQuality) { return size }
        return item.durationMs > 0 ? Feeds.estimatedBytes(durationMs: item.durationMs) : nil
    }

    /// The YouTube cookies (members-only videos) as a temporary cookies.txt (0600); the caller deletes it.
    public func cookiesFile() async -> URL? {
        guard let remote, let key = prefs.pairingKey else { return nil }
        do {
            guard let data = try await remote.cookies(key: key) else { return nil }
            let url = FileManager.default.temporaryDirectory.appending(path: "cookies-\(UUID().uuidString).txt")
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
            return url
        } catch {
            log.warning("No cookies: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // Comments

    private var commentsDirectory: URL { directory.appending(path: "comments", directoryHint: .isDirectory) }

    /// The video's top comments: the saved copy unless `fresh` (downloaded videos keep theirs, to
    /// read offline), else fetched with yt-dlp and saved.
    public func comments(_ video: Video, fresh: Bool = false) async throws -> CommentsPage {
        let file = commentsDirectory.appending(path: "\(video.id).json")
        if !fresh, let text = try? String(contentsOf: file, encoding: .utf8), let page = try? Comments.parse(text) { return page }
        let cookies = video.isMembersOnly ? await cookiesFile() : nil
        defer { if let cookies { try? FileManager.default.removeItem(at: cookies) } }
        let trimmed = try Comments.trim(try await youtube.comments(videoId: video.id, cookies: cookies))
        try? FileManager.default.createDirectory(at: commentsDirectory, withIntermediateDirectories: true)
        try? Data(trimmed.utf8).write(to: file, options: .atomic)
        pruneComments()
        return try Comments.parse(trimmed)
    }

    /// Saved comments of videos that aren't downloaded go after a week.
    private func pruneComments() {
        let keep = Set(downloadIds())
        let cutoff = Date.now.addingTimeInterval(-7 * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: commentsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where !keep.contains(file.deletingPathExtension().lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    // Actions

    private func queue(_ id: String, sentAt: Date, video: Video?, requestedAt: Date? = nil) {
        local.update(id) { existing in
            LocalVideo(id: id, state: .queued, durationMs: existing?.durationMs ?? 0, positionMs: existing?.positionMs ?? 0, sentAt: sentAt,
                       video: video ?? existing?.video, requestedAt: requestedAt ?? existing?.requestedAt)
        }
        downloads.enqueue(id, fresh: true)
    }

    /// Downloads any video: retries a sent one, or asks for one picked from a channel page or search.
    public func download(_ item: VideoItem) {
        guard !item.isPlayable, !item.isDownloading else { return }
        if let sent = item.sent {
            queue(item.id, sentAt: sent.sentAt ?? .now, video: item.video)
        } else {
            let now = Date.now
            queue(item.id, sentAt: now, video: item.video, requestedAt: now)
        }
        sendPendingRequests()
    }

    public func setWatched(_ id: String, _ watched: Bool) {
        let item = item(id)
        if watched, item?.watched == false, let channelId = item?.video.channelId, !channelId.isEmpty {
            stats.addFinished(channelId)
        }
        guard item?.sent != nil, !isUnfiledRequest(id) else {
            // Streamed without ever being sent (or the request isn't filed yet, and carries it): remember it here.
            prefs.setWatchedHere(id, watched)
            rebuildItems()
            return
        }
        pushWatched(id, watched)
    }

    private func pushWatched(_ id: String, _ watched: Bool) {
        if isDemo {
            serverSent = serverSent.map { video in
                guard video.video.id == id else { return video }
                var video = video
                video.watched = watched
                return video
            }
        } else {
            pendingWatched[id] = (watched, .now)
        }
        rebuildItems()
        guard !isDemo, let remote else { return }
        Task {
            do { try await remote.setWatched(id, watched: watched) } catch {
                log.warning("setWatched failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func savePosition(_ id: String, positionMs: Int, durationMs: Int) {
        guard local[id] != nil else { return }
        local.update(id) { existing in
            existing.map { video in
                var video = video
                video.positionMs = positionMs
                if durationMs > 0 { video.durationMs = durationMs }
                return video
            }
        }
    }

    public func retry(_ id: String) {
        queue(id, sentAt: local[id]?.sentAt ?? Date(timeIntervalSince1970: 0), video: items[id]?.video)
        sendPendingRequests()
    }

    /// Stops a download under way or deletes the file. (Unlike Android, it doesn't tell the Mac.)
    public func deleteDownload(_ id: String) {
        downloads.cancel(id)
        local.deleteFiles(for: id)
        local.update(id) { existing in
            existing.map { video in
                var video = video
                video.state = .deleted
                video.fileName = nil
                video.sizeBytes = 0
                video.progress = 0
                video.error = nil
                return video
            }
        }
    }

    /// Videos downloaded, downloading or waiting to download.
    public func downloadIds() -> [String] { downloadItems.map(\.id) }

    /// Deletes every download, stops the ones under way, and clears out anything left in the folder.
    public func deleteAllDownloads() {
        downloadIds().forEach(deleteDownload)
        let folder = local.downloadsDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// Re-checks waiting downloads under the new network rule.
    public func setWifiOnly(_ on: Bool) {
        prefs.setWifiOnly(on)
        downloads.reevaluate()
    }

    public func storageUsedBytes() -> Int64 { local.storageUsedBytes() }

    // Channel groups

    private func editGroups(_ change: @escaping @Sendable ([ChannelGroup]) -> [ChannelGroup]) {
        shared.groups = change(shared.groups)
        guard !isDemo, let remote else { return }
        groupEditsInFlight += 1
        Task {
            do { try await remote.editGroups(change) } catch {
                log.warning("Saving groups failed: \(String(describing: error), privacy: .public)")
            }
            groupEditsInFlight -= 1
            if groupEditsInFlight == 0, let state = try? await remote.shared() { applyShared(state) }
        }
    }

    @discardableResult
    public func createGroup(_ name: String, with channel: GroupChannel? = nil) -> ChannelGroup {
        let group = ChannelGroup(id: UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 channels: channel.map { [$0] } ?? [])
        editGroups { $0 + [group] }
        return group
    }

    public func renameGroup(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        editGroups { groups in groups.map { group in
            guard group.id == id else { return group }
            var group = group
            group.name = name
            return group
        } }
    }

    public func deleteGroup(_ id: String) { editGroups { $0.filter { $0.id != id } } }

    public func setInGroup(_ groupId: String, channel: GroupChannel, included: Bool) {
        editGroups { groups in groups.map { group in
            guard group.id == groupId else { return group }
            var group = group
            group.channels = group.channels.filter { $0.id != channel.id } + (included ? [channel] : [])
            return group
        } }
    }

    /// Moves a group one place up (-1) or down (+1).
    public func moveGroup(_ id: String, by offset: Int) {
        editGroups { groups in
            guard let from = groups.firstIndex(where: { $0.id == id }), groups.indices.contains(from + offset) else { return groups }
            var groups = groups
            groups.insert(groups.remove(at: from), at: from + offset)
            return groups
        }
    }

    // Playlists

    /// Adding a video that isn't downloaded yet downloads it.
    public func addToPlaylist(_ playlistId: String, _ item: VideoItem) {
        playlistStore.add(playlistId, videoId: item.id)
        download(item)
    }

    @discardableResult
    public func createPlaylist(_ name: String, with item: VideoItem? = nil) -> Playlist {
        let playlist = playlistStore.create(name, firstVideo: item?.id)
        if let item { download(item) }
        return playlist
    }
}

extension Repository: DownloadHost {
    public func videoToDownload(_ id: String) async throws -> Video? {
        if let video = items[id]?.video ?? local[id]?.video { return video }
        guard let remote, isPaired else { return nil }
        return try await remote.video(id)?.video
    }

    public func downloadFinished(_ video: Video) {
        // Its comments too, to read offline (best effort).
        Task { _ = try? await comments(video, fresh: true) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
