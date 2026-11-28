import Foundation
import Observation
import os

/// What the Settings footer and pull-to-refresh say about the checks.
public struct CheckStatus: Equatable, Sendable {
    public var isChecking: Bool
    public var lastCheck: CheckRecord?
    public var channelErrors: [String: String]
    public var backoffUntil: Date?
    public var failedCheckStreak: Int
    public var channelCount: Int
    /// When the followed channels were last read: the last check that reached YouTube, or a later
    /// seed (a channel just added) or the Mac's channels just adopted. Nil: never.
    public var lastReadAt: Date?

    public init(isChecking: Bool, lastCheck: CheckRecord?, channelErrors: [String: String], backoffUntil: Date?,
                failedCheckStreak: Int, channelCount: Int, lastReadAt: Date? = nil) {
        self.isChecking = isChecking
        self.lastCheck = lastCheck
        self.channelErrors = channelErrors
        self.backoffUntil = backoffUntil
        self.failedCheckStreak = failedCheckStreak
        self.channelCount = channelCount
        self.lastReadAt = lastReadAt
    }

    /// The later of the last check that reached YouTube and the newest uploads read among the
    /// followed channels.
    public static func lastReadAt(_ state: StandaloneState) -> Date? {
        let checked = state.lastCheck.flatMap { $0.offline ? nil : $0.finishedAt }
        let read = state.channels.compactMap { state.fetchedAt[$0.id]?.uploads }.max()
        // Android writes 0 for "never".
        return [checked, read].compactMap { $0 }.filter { $0.timeIntervalSince1970 > 0 }.max()
    }

    /// The last check couldn't reach YouTube, and nothing was read since.
    public var couldntReachYouTube: Bool {
        guard let last = lastCheck, last.offline else { return false }
        return lastReadAt.map { last.finishedAt >= $0 } ?? true
    }

    /// After this many failing checks in a row the footer says so.
    public static let failureStreak = 3

    /// "Checks are failing: …" once three checks in a row had errors.
    public var failingMessage: String? {
        guard failedCheckStreak >= Self.failureStreak, let first = lastCheck?.errors.first else { return nil }
        return "Checks are failing: \(first)"
    }
}

/// Standalone mode: the phone does the Mac's jobs itself. It follows channels and checks them for
/// new videos (RSS over plain HTTP, yt-dlp for past streams and members-only videos), reads
/// YouTube's Home and Subscriptions with the phone's own sign-in, and syncs watched state with
/// YouTube's history. Everything lives in standalone.json and the cookie vault; nothing touches
/// Firebase.
///
/// The Repository owns one while the mode is standalone and maps its state into what the screens
/// already read (`channels`, `youtubeFeeds`, `shared.groups`); `onChange` tells it when.
@MainActor
@Observable
public final class StandaloneEngine {
    public private(set) var state: StandaloneState
    public private(set) var isChecking = false
    /// Why the last watched sync failed (shown under the toggle).
    public private(set) var watchSyncError: String?

    @ObservationIgnored public let store: StandaloneStore
    @ObservationIgnored public let account: YouTubeAccount
    @ObservationIgnored public let web: YouTubeWeb
    @ObservationIgnored public let youtube: YouTubeTool
    @ObservationIgnored let checker: ChannelChecker
    @ObservationIgnored let prefs: Prefs
    /// Downloads and other videos the phone knows, for the history rule (the Repository sets it).
    @ObservationIgnored public var knownVideoIds: () -> Set<String> = { [] }
    /// The state the screens read changed.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// YouTube stopped accepting the sign-in (once per transition): the app posts a notification.
    @ObservationIgnored public var onExpired: (() -> Void)?
    /// The clock (tests move it).
    @ObservationIgnored public var now: () -> Date = { .now }

    @ObservationIgnored private var running: Task<RefreshResult, Never>?
    @ObservationIgnored private var runningTrigger: CheckTrigger?
    @ObservationIgnored private var lastPullResult: RefreshResult?
    @ObservationIgnored private var syncingWatched = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var stopped = false
    /// Bumped on every sign-in and sign-out: answers read with older cookies are dropped.
    @ObservationIgnored private var authGeneration = 0
    @ObservationIgnored private let log = Logger(subsystem: "dev.stow.ios", category: "standalone")

    // The Mac's numbers.
    public static let recentPerChannel = 30
    public static let maxConcurrentChannels = 3
    public static let feedLimit = 150
    public static let accessChecksPerPass = 15
    public static let avatarLookupsPerRead = 20
    public static let avatarCacheLimit = 1000
    public static let pullReuse: TimeInterval = 60
    public static let probeInterval: TimeInterval = 3600

    public init(directory: URL, youtube: YouTubeTool, prefs: Prefs, vault: CookieVault, session: URLSession? = nil) {
        store = StandaloneStore(directory: directory)
        state = store.load()
        account = YouTubeAccount(vault: vault)
        web = YouTubeWeb(session: session)
        self.youtube = youtube
        self.prefs = prefs
        checker = ChannelChecker(web: web, youtube: youtube)
        let hasVaultItem = account.cookiesText != nil
        if state.account.hasCookies, !hasVaultItem {
            // The vault went (a restore elsewhere): signed out, not "signed in" without cookies.
            clearAccount()
            store.save(state)
        } else if !state.account.hasCookies, hasVaultItem {
            // A sign-in nothing uses: the Keychain outlives a deleted app, standalone.json doesn't.
            do {
                try account.delete()
                log.info("Deleted a YouTube sign-in left from an earlier install")
            } catch {
                log.warning("Couldn't delete a leftover YouTube sign-in: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Stops for good (leaving standalone mode): a running check's answers are dropped.
    public func stop() {
        stopped = true
        running?.cancel()
    }

    // What the screens read

    public var channels: [FollowedChannel] { state.channels }
    public var followedIds: Set<String> { Set(state.channels.map(\.id)) }
    public func isFollowing(_ channelId: String) -> Bool { state.isFollowing(channelId) }
    public var groups: [ChannelGroup] { state.groups }
    public var accountInfo: StandaloneAccount { state.account }
    public var isSignedIn: Bool { state.account.state == .signedIn }

    public var checkStatus: CheckStatus {
        CheckStatus(isChecking: isChecking, lastCheck: state.lastCheck, channelErrors: state.channelErrors,
                    backoffUntil: state.backoffUntil, failedCheckStreak: state.failedCheckStreak, channelCount: state.channels.count,
                    lastReadAt: CheckStatus.lastReadAt(state))
    }

    /// The followed channels as the Repository's `channels`: recent videos after the members-only rules.
    public var repositoryChannels: [Channel] {
        state.channels.enumerated().map { index, channel in
            let recent = RecentMerge.visible((state.recentVideos[channel.id] ?? []).map(\.video), access: state.access)
            return Channel(id: channel.id, title: channel.title, handle: channel.handle, avatarURL: channel.avatarURL,
                           order: index, recent: recent.map { RecentVideo(video: $0, watched: false) })
        }
    }

    /// YouTube's Home and Subscriptions as last read, without members-only videos the account can't watch.
    public var youtubeFeeds: YouTubeFeeds {
        guard let feeds = state.accountFeeds else { return YouTubeFeeds() }
        let known = knownDates()
        func prepared(_ videos: [StoredVideo]) -> [Video] {
            RecentMerge.visible(videos.map { stored in
                var video = stored.video
                if video.publishedAt == nil { video.publishedAt = known[video.id] }
                return video
            }, access: state.access)
        }
        var avatars = state.channelAvatars
        avatars.merge(feeds.channelAvatars) { _, new in new }
        return YouTubeFeeds(recommended: prepared(feeds.recommended), subscriptions: prepared(feeds.subscriptions), channelAvatars: avatars)
    }

    private func knownDates() -> [String: Date] {
        var dates: [String: Date] = [:]
        for videos in state.recentVideos.values {
            for video in videos { if let date = video.publishedAt { dates[video.id] = date } }
        }
        return dates
    }

    // Scheduling

    /// An automatic check (launch, back on screen, the minute timer): runs when about 15 minutes
    /// have passed since the last one started (one that couldn't reach YouTube doesn't count) and
    /// no backoff is on. A running check is joined instead.
    public func checkIfDue(_ trigger: CheckTrigger) async {
        guard !stopped else { return }
        if let running {
            _ = await running.value
            return
        }
        guard CheckPlan.isDue(trigger: trigger, last: state.lastCheck, backoffUntil: state.backoffUntil, now: now()) else {
            log.info("Check (\(trigger.rawValue, privacy: .public)): not due")
            return
        }
        _ = await run(trigger)
    }

    /// Pull to refresh: a check now, backoff or not. One within a minute of the last pull gives
    /// that answer; one during another check waits for it, then checks.
    public func refresh() async -> RefreshResult {
        guard !stopped else { return .failed }
        if runningTrigger == .pull, let running { return await running.value }
        if running == nil, let last = state.lastPullAt, let lastPullResult, now().timeIntervalSince(last) < Self.pullReuse {
            return lastPullResult
        }
        let result = await run(.pull)
        state.lastPullAt = now()
        lastPullResult = result
        store.save(state)
        return result
    }

    /// A check now, whatever the schedule.
    public func checkNow(_ trigger: CheckTrigger) async -> RefreshResult {
        guard !stopped else { return .failed }
        return await run(trigger)
    }

    /// For the BGAppRefreshTask (about 30 seconds): the RSS round and a due history sync only.
    public func backgroundRefresh() async -> Bool {
        guard !stopped else { return false }
        if let running { return await running.value == .done }
        guard CheckPlan.isDue(trigger: .background, last: state.lastCheck, backoffUntil: state.backoffUntil, now: now()) else { return true }
        return await run(.background) == .done
    }

    /// One check at a time: waits for the running one, then runs.
    private func run(_ trigger: CheckTrigger, only: [String]? = nil) async -> RefreshResult {
        while let current = running { _ = await current.value }
        guard !stopped else { return .failed }
        let task = Task { () -> RefreshResult in
            let result = await self.performCheck(trigger, only: only)
            self.running = nil
            self.runningTrigger = nil
            self.isChecking = false
            return result
        }
        running = task
        runningTrigger = trigger
        isChecking = true
        return await task.value
    }

    // A check

    private func performCheck(_ trigger: CheckTrigger, only: [String]?) async -> RefreshResult {
        let startedAt = now()
        var errors: [String] = []
        var rateLimited = false
        if state.account.state == .signedIn, account.loginInfoExpired(now: startedAt) { markExpired() }
        if state.account.state == .expired, trigger != .background, state.account.lastProbeAt.map({ startedAt.timeIntervalSince($0) >= Self.probeInterval }) ?? true {
            await probe()
        }
        let generation = authGeneration
        let cookies = state.account.state == .signedIn ? account.temporaryFile() : nil
        defer { if let cookies { try? FileManager.default.removeItem(at: cookies) } }

        let checked = only.map { ids in state.channels.filter { ids.contains($0.id) } } ?? state.channels
        let plan = CheckPlan.plan(
            trigger: trigger, channels: checked.map(\.id), fetchedAt: state.fetchedAt,
            account: .init(state: state.account.state, syncWatched: state.syncWatchedWithYouTube,
                           pendingMarks: !state.pendingYouTubeWatched.isEmpty, lastWatchSync: state.lastWatchSync,
                           feedsLoadedAt: state.accountFeeds?.loadedAt),
            skippedMembers: CheckPlan.skippedMembers(nonMember: state.nonMemberChannels, noPlaylist: state.noMembersPlaylist, now: startedAt),
            now: startedAt)

        // The channels, three at a time; each answer is applied as it comes.
        var offline = 0
        var authExpired = false
        var membersWorked = false
        let checker = checker
        await withTaskGroup(of: ChannelFetchResult.self) { group in
            var pending = checked.makeIterator()
            func addNext() {
                guard let channel = pending.next(), let feeds = plan.feeds(channel.id) else { return }
                group.addTask { await checker.fetch(channel, feeds: feeds, cookies: cookies) }
            }
            for _ in 0..<Self.maxConcurrentChannels { addNext() }
            var applied = 0
            for await result in group {
                guard !stopped else { group.cancelAll(); return }
                apply(result, feeds: plan.feeds(result.channelId) ?? .init(), now: now())
                errors += result.errors
                if result.offline { offline += 1 }
                if result.authExpired { authExpired = true }
                if result.membersSucceeded { membersWorked = true }
                applied += 1
                if applied % Self.maxConcurrentChannels == 0 { store.save(state) }
                if result.rateLimited {
                    rateLimited = true
                    group.cancelAll()
                    continue
                }
                if !rateLimited { addNext() }
            }
        }
        guard !stopped else { return .failed }
        if generation == authGeneration {
            if authExpired {
                markExpired()
            } else if state.account.state == .expired, membersWorked {
                setSignedInAgain()
            }
        }
        updateMembership()
        publish()

        if plan.accountFeeds, !rateLimited, state.account.state == .signedIn, generation == authGeneration {
            do {
                try await readAccountFeeds(cookies: cookies, generation: generation)
            } catch {
                if ChannelChecker.isRateLimit(error) { rateLimited = true }
                errors.append("Home and Subscriptions failed: \(YouTubeFailure.message(error))")
            }
        }
        guard !stopped else { return .failed }
        if plan.accessChecks, !rateLimited, state.account.state == .signedIn, let cookies {
            await checkMemberAccess(cookies: cookies, generation: generation)
        }
        guard !stopped else { return .failed }
        if plan.history, !rateLimited, state.account.state == .signedIn {
            await syncWatched()
        }
        guard !stopped else { return .failed }

        let finishedAt = now()
        if rateLimited {
            state.backoffMinutes = CheckPlan.nextBackoff(previousMinutes: state.backoffMinutes)
            state.backoffUntil = finishedAt.addingTimeInterval(TimeInterval(state.backoffMinutes * 60))
        }
        // A new channel's first fetch (`only`) isn't a check of the channels: the schedule, the
        // failure streak and an active backoff stay as the last full check left them.
        let couldntReach = !checked.isEmpty && offline * 2 > checked.count
        if only == nil {
            state.lastCheck = CheckRecord(trigger: trigger.rawValue, startedAt: startedAt, finishedAt: finishedAt,
                                          channelsChecked: checked.count, errors: errors, offline: couldntReach)
            state.failedCheckStreak = errors.isEmpty ? 0 : state.failedCheckStreak + 1
            if !rateLimited, errors.isEmpty {
                state.backoffMinutes = 0
                state.backoffUntil = nil
            }
        }
        store.save(state)
        publish()
        let seconds = finishedAt.timeIntervalSince(startedAt)
        log.info("\(only == nil ? "Check" : "Seed", privacy: .public) (\(trigger.rawValue, privacy: .public)): \(checked.count) channels, \(errors.count) errors, \(seconds, format: .fixed(precision: 1)) s")
        for error in errors.prefix(10) { log.warning("\(error, privacy: .public)") }

        if rateLimited { return .slowedDown }
        if couldntReach { return .youtubeFailed }
        return .done
    }

    /// One channel's answer: merged into its recent videos (the Mac's `apply`).
    private func apply(_ result: ChannelFetchResult, feeds: CheckPlan.Feeds, now: Date) {
        // Removed while its feeds were loading.
        guard let channel = state.channels.first(where: { $0.id == result.channelId }) else { return }
        let id = channel.id
        var times = state.fetchedAt[id] ?? FeedTimes()
        if result.sources[.uploads] != nil { times.uploads = now }
        if result.sources[.streams] != nil { times.streams = now }
        if result.sources[.members] != nil || result.noMembersPlaylist { times.members = now }
        state.fetchedAt[id] = times
        if result.noMembersPlaylist { state.noMembersPlaylist[id] = now }
        if result.notFound {
            state.channelErrors[id] = "Channel not found"
        } else if result.sources[.uploads] != nil {
            state.channelErrors[id] = nil
        }
        let fetched = result.sources.values.flatMap { $0 }.map { RecentMerge.normalized($0, channel: channel) }
        guard !fetched.isEmpty else { return }
        let stored = state.recentVideos[id] ?? []
        let before = Set(stored.map(\.id))
        state.recentVideos[id] = RecentMerge.merge(stored, with: fetched, now: now, cap: Self.recentPerChannel,
                                                   approximate: result.approximateDates)
        // Watched on YouTube before Stow found it: watched here too.
        let history = Set(state.youTubeHistory)
        for video in fetched where !before.contains(video.id) && history.contains(video.id) {
            prefs.setWatchedHere(video.id, true)
        }
    }

    /// A channel whose members videos are all "join this channel" isn't one the account is a
    /// member of: its members feeds wait a week. One watchable video clears that.
    private func updateMembership(now: Date? = nil) {
        let now = now ?? self.now()
        let videos = state.recentVideos.values.flatMap { $0 }.filter(\.isMembersOnly)
        for (channelId, members) in Dictionary(grouping: videos, by: \.channelId) {
            let access = members.compactMap { state.access($0.id) }
            if access.contains(.watchable) {
                state.nonMemberChannels[channelId] = nil
            } else if access.contains(.locked(level: nil)),
                      !CheckPlan.skippedMembers(nonMember: state.nonMemberChannels, noPlaylist: [:], now: now).contains(channelId) {
                state.nonMemberChannels[channelId] = now
            }
        }
    }

    // YouTube's Home and Subscriptions

    private func readAccountFeeds(cookies: URL?, generation: Int) async throws {
        guard let cookies else { return }
        let youtube = youtube
        let limiter = checker.ytdlp
        async let recommendedListing = limiter.run { try await youtube.flatListing(":ytrec", count: Self.feedLimit, cookies: cookies) }
        async let subscriptionsListing = limiter.run { try await youtube.flatListing(":ytsubs", count: Self.feedLimit, cookies: cookies) }
        var listings: (FlatListing, FlatListing)
        do {
            listings = try await (recommendedListing, subscriptionsListing)
        } catch {
            if YouTubeFailure.classify(error) == .auth, generation == authGeneration { markExpired() }
            throw error
        }
        let (recommended, subscriptions) = listings
        guard generation == authGeneration, !stopped else { return }
        if recommended.cookiesRejected || subscriptions.cookiesRejected {
            markExpired()
            throw StandaloneError.auth
        }
        let foundAt = now()
        let feeds = StoredFeeds(recommended: try YouTubeListing.parse(recommended.json).map { StoredVideo($0, foundAt: foundAt) },
                                subscriptions: try YouTubeListing.parse(subscriptions.json).map { StoredVideo($0, foundAt: foundAt) },
                                channelAvatars: [:], loadedAt: foundAt)
        await lookUpAvatars(for: feeds)
        var withAvatars = feeds
        var avatars: [String: String] = [:]
        for video in feeds.recommended + feeds.subscriptions where avatars[video.channelId] == nil {
            avatars[video.channelId] = state.channels.first { $0.id == video.channelId }?.avatarURL ?? state.channelAvatars[video.channelId]
        }
        withAvatars.channelAvatars = avatars
        state.accountFeeds = withAvatars
        store.save(state)
        publish()
    }

    /// The feeds name each video's channel but not its picture: the ones Stow doesn't know come
    /// from the channel pages (at most 20 per read, 3 at a time).
    private func lookUpAvatars(for feeds: StoredFeeds) async {
        var missing: [String] = []
        for video in feeds.recommended + feeds.subscriptions
        where !video.channelId.isEmpty && state.channelAvatars[video.channelId] == nil && !isFollowing(video.channelId)
            && !missing.contains(video.channelId) {
            missing.append(video.channelId)
        }
        missing = Array(missing.prefix(Self.avatarLookupsPerRead))
        guard !missing.isEmpty else { return }
        let web = web
        let found = await withTaskGroup(of: (String, String?).self) { group in
            var found: [String: String] = [:]
            for (index, id) in missing.enumerated() {
                if index >= 3, let (id, url) = await group.next() { found[id] = url }
                group.addTask {
                    let page = try? await web.get(ChannelResolver.channelURL(id: id))
                    return (id, page.flatMap { $0.status == 200 ? ChannelPageParser.parse(html: $0.text)?.avatarURL : nil })
                }
            }
            for await (id, url) in group { found[id] = url }
            return found.compactMapValues { $0 }
        }
        guard !found.isEmpty else { return }
        if state.channelAvatars.count + found.count > Self.avatarCacheLimit {
            let current = Set((feeds.recommended + feeds.subscriptions).map(\.channelId))
            state.channelAvatars = state.channelAvatars.filter { current.contains($0.key) }
        }
        state.channelAvatars.merge(found) { _, new in new }
    }

    // Members-only access

    private func checkMemberAccess(cookies: URL, generation: Int) async {
        var seen = Set<String>()
        let candidates = (state.recentVideos.values.flatMap { $0 } + (state.accountFeeds.map { $0.recommended + $0.subscriptions } ?? []))
            .filter { $0.isMembersOnly && state.access($0.id) == nil && seen.insert($0.id).inserted }
            .prefix(Self.accessChecksPerPass)
        guard !candidates.isEmpty else { return }
        var changed = false
        for video in candidates {
            guard state.account.state == .signedIn, generation == authGeneration, !stopped else { break }
            do {
                let access = try await checker.access(videoId: video.id, cookies: cookies)
                state.memberAccess[video.id] = access.stored
                changed = true
            } catch StandaloneError.auth {
                markExpired()
                break
            } catch {
                continue // Asked again on the next check.
            }
        }
        guard changed else { return }
        updateMembership()
        let known = Set(state.recentVideos.values.flatMap { $0.map(\.id) }
            + (state.accountFeeds.map { ($0.recommended + $0.subscriptions).map(\.id) } ?? []))
        state.memberAccess = state.memberAccess.filter { known.contains($0.key) }
        store.save(state)
        publish()
    }

    // The sign-in

    /// Stores a sign-in: from the web login (`source: .web`) or a cookies.txt (`.file`). Only the
    /// youtube.com and google.com cookies are kept. With `verify`, YouTube must accept them first
    /// (`.rejected` otherwise; a network failure stores them, and the next check tells).
    public func signIn(cookies text: String, source: AccountSource, verify: Bool = true) async throws {
        let normalized = try YouTubeAccount.validated(text, now: now())
        if verify {
            let url = FileManager.default.temporaryDirectory.appending(path: "cookies-\(UUID().uuidString).txt")
            guard FileManager.default.createFile(atPath: url.path, contents: Data(normalized.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw StandaloneError.other("Couldn't save the sign-in.")
            }
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let listing = try await youtube.flatListing(":ytsubs", count: 1, cookies: url)
                if listing.cookiesRejected { throw StandaloneError.rejected }
            } catch StandaloneError.rejected {
                throw StandaloneError.rejected
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if YouTubeFailure.classify(error) == .auth { throw StandaloneError.rejected }
                log.info("Couldn't verify the sign-in, storing it: \(YouTubeFailure.message(error), privacy: .public)")
            }
        }
        guard !stopped else { return }
        do {
            try account.store(normalized)
        } catch {
            log.error("Couldn't keep the sign-in: \(error.localizedDescription, privacy: .public)")
            throw StandaloneError.other("Couldn't keep the sign-in on this phone. Try again.")
        }
        authGeneration += 1
        state.account = StandaloneAccount(state: .signedIn, since: now(), source: source)
        prefs.expiredBannerClosed = false
        prefs.signInPromptPending = false
        watchSyncError = nil
        store.save(state)
        publish()
        Task { _ = await self.run(.signIn) }
    }

    /// Signs out: the vault item goes, and so does everything read with it.
    public func signOut() {
        authGeneration += 1
        clearAccount()
        store.save(state)
        publish()
    }

    private func clearAccount() {
        do {
            try account.delete()
        } catch {
            log.error("Couldn't delete the sign-in: \(error.localizedDescription, privacy: .public)")
        }
        state.account = .signedOut
        state.accountFeeds = nil
        state.memberAccess = [:]
        state.nonMemberChannels = [:]
        state.noMembersPlaylist = [:]
        state.youTubeHistory = []
        state.pendingYouTubeWatched = []
        state.lastWatchSync = nil
        watchSyncError = nil
    }

    /// YouTube stopped taking the sign-in (sticky): a notification and a banner, once.
    public func markExpired() {
        guard state.account.state == .signedIn else { return }
        state.account.state = .expired
        state.account.lastProbeAt = now()
        prefs.expiredBannerClosed = false
        store.save(state)
        publish()
        log.warning("YouTube rejected the sign-in")
        onExpired?()
    }

    private func setSignedInAgain() {
        state.account.state = .signedIn
        log.info("YouTube sign-in works again")
    }

    /// While expired: one `:ytsubs` read at most hourly; accepted means signed in again.
    private func probe() async {
        state.account.lastProbeAt = now()
        guard let cookies = account.temporaryFile() else { return }
        defer { try? FileManager.default.removeItem(at: cookies) }
        let generation = authGeneration
        do {
            let listing = try await youtube.flatListing(":ytsubs", count: 1, cookies: cookies)
            if !listing.cookiesRejected, generation == authGeneration, state.account.state == .expired { setSignedInAgain() }
        } catch {
            log.info("Sign-in probe: \(YouTubeFailure.message(error), privacy: .public)")
        }
        store.save(state)
        publish()
    }

    /// The sign-in's cookies for one yt-dlp call (streams, downloads, comments of members-only
    /// videos), only while YouTube takes them. The caller deletes the file.
    public func cookiesFile() -> URL? {
        state.account.state == .signedIn ? account.temporaryFile() : nil
    }

    /// The Home banner after YouTube signed the phone out (closable until the next time).
    public var showsExpiredBanner: Bool { state.account.state == .expired && !prefs.expiredBannerClosed }

    public func closeExpiredBanner() { prefs.expiredBannerClosed = true }

    /// After switching from the Mac: one card on Home suggests signing in here.
    public var showsSignInPrompt: Bool { prefs.signInPromptPending && state.account.state == .signedOut }

    public func closeSignInPrompt() { prefs.signInPromptPending = false }

    // Watched

    /// Marked (un)watched on the phone: queued for YouTube while syncing (YouTube can't unwatch).
    public func noteWatched(_ videoId: String, _ watched: Bool) {
        if watched {
            guard state.syncWatchedWithYouTube, state.account.hasCookies, !state.pendingYouTubeWatched.contains(videoId) else { return }
            state.pendingYouTubeWatched.append(videoId)
            store.save(state)
            if state.account.state == .signedIn { Task { await self.syncWatched() } }
        } else if state.pendingYouTubeWatched.contains(videoId) {
            state.pendingYouTubeWatched.removeAll { $0 == videoId }
            store.save(state)
        }
    }

    public func setSyncWatched(_ on: Bool) {
        state.syncWatchedWithYouTube = on
        if on {
            Task { await self.syncWatched() }
        } else {
            state.pendingYouTubeWatched = []
            watchSyncError = nil
        }
        store.save(state)
    }

    /// Sends the phone's watched marks to YouTube (at most 10, oldest first), then reads the
    /// history and marks here what was watched on YouTube since the last read.
    public func syncWatched() async {
        guard state.syncWatchedWithYouTube, state.account.state == .signedIn, !stopped else { return }
        guard !syncingWatched else {
            syncAgain = true
            return
        }
        syncingWatched = true
        defer { syncingWatched = false }
        repeat {
            syncAgain = false
            await runWatchSync()
        } while syncAgain && state.account.state == .signedIn && !stopped
    }

    private func runWatchSync() async {
        guard let cookies = account.temporaryFile() else { return }
        defer { try? FileManager.default.removeItem(at: cookies) }
        let generation = authGeneration
        do {
            for videoId in state.pendingYouTubeWatched.prefix(WatchSync.pushesPerSync) {
                do {
                    try await checker.ytdlp.run { [youtube] in try await youtube.markWatched(videoId: videoId, cookies: cookies) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error where YouTubeFailure.classify(error) == .unavailable {
                    _ = error
                    log.warning("Couldn't mark \(videoId, privacy: .public) watched on YouTube: it's unavailable")
                }
                guard generation == authGeneration else { return }
                state.pendingYouTubeWatched.removeAll { $0 == videoId }
                store.save(state)
            }
            let youtube = youtube
            let listing = try await checker.ytdlp.run { try await youtube.flatListing(":ythistory", count: WatchSync.historyLimit, cookies: cookies) }
            guard generation == authGeneration, state.syncWatchedWithYouTube, !stopped else { return }
            if listing.cookiesRejected { throw StandaloneError.auth }
            let history = try WatchSync.parseHistory(listing.json)
            let newly = WatchSync.newlyWatched(history: history, previous: state.youTubeHistory)
            let known = knownIds()
            for id in newly where known.contains(id) && !prefs.watchedHere.contains(id) {
                prefs.setWatchedHere(id, true)
            }
            state.youTubeHistory = history
            state.lastWatchSync = now()
            watchSyncError = nil
            store.save(state)
            publish()
        } catch is CancellationError {
        } catch {
            guard generation == authGeneration else { return }
            if YouTubeFailure.classify(error) == .auth { markExpired() }
            watchSyncError = YouTubeFailure.message(error)
            log.warning("Watched sync failed: \(self.watchSyncError ?? "", privacy: .public)")
        }
    }

    /// Videos the phone knows: followed channels' recent ones, YouTube's feeds, downloads.
    private func knownIds() -> Set<String> {
        var ids = knownVideoIds()
        for videos in state.recentVideos.values { ids.formUnion(videos.map(\.id)) }
        if let feeds = state.accountFeeds { ids.formUnion((feeds.recommended + feeds.subscriptions).map(\.id)) }
        return ids
    }

    // Channels

    /// Follows a channel and fetches it right away. False when it was followed already.
    @discardableResult
    public func follow(_ info: ChannelInfo) -> Bool {
        guard !isFollowing(info.id) else { return false }
        state.channels.append(FollowedChannel(info, addedAt: now()))
        store.save(state)
        publish()
        if info.avatarURL == nil || info.handle == nil { lookUpDetails(info.id) }
        Task { _ = await self.run(.channelAdded, only: [info.id]) }
        return true
    }

    /// Resolves what was typed (URL, @handle, channel ID, video URL), follows it and fetches it.
    @discardableResult
    public func addChannel(input: String) async throws -> FollowedChannel {
        let info = try await ChannelResolver(web: web, youtube: youtube).resolve(input: input)
        if let existing = state.channels.first(where: { $0.id == info.id }) {
            throw StandaloneError.alreadyAdded(existing.title)
        }
        follow(info)
        return state.channels.first { $0.id == info.id } ?? FollowedChannel(info)
    }

    /// Follows the picked subscriptions (skipping followed ones), fetching three at a time.
    @discardableResult
    public func addChannels(_ picked: [ChannelInfo]) -> Int {
        var ids = followedIds
        let added = picked.filter { ids.insert($0.id).inserted }
        guard !added.isEmpty else { return 0 }
        state.channels += added.map { FollowedChannel($0, addedAt: now()) }
        store.save(state)
        publish()
        Task {
            for start in stride(from: 0, to: added.count, by: Self.maxConcurrentChannels) {
                let batch = added[start..<min(start + Self.maxConcurrentChannels, added.count)].map(\.id)
                _ = await self.run(.channelAdded, only: batch)
            }
        }
        return added.count
    }

    /// The account's YouTube subscriptions, for the import picker.
    public func loadSubscriptions() async throws -> [ChannelInfo] {
        guard state.account.state == .signedIn else { throw StandaloneError.auth }
        do {
            return try await SubscriptionsImport(web: web).fetch(cookies: account.cookies, now: now())
        } catch StandaloneError.auth {
            markExpired()
            throw StandaloneError.auth
        }
    }

    /// Picture and handle for a channel followed with only its id and title (a search row, a group).
    private func lookUpDetails(_ channelId: String) {
        let resolver = ChannelResolver(web: web, youtube: youtube)
        Task {
            guard let info = try? await resolver.resolve(input: channelId) else { return }
            guard let index = state.channels.firstIndex(where: { $0.id == channelId }) else { return }
            if state.channels[index].avatarURL == nil { state.channels[index].avatarURL = info.avatarURL }
            if state.channels[index].handle == nil { state.channels[index].handle = info.handle }
            if state.channels[index].title.isEmpty { state.channels[index].title = info.title }
            store.save(state)
            publish()
        }
    }

    /// Unfollows (the Mac's `removeChannel`): its videos, check state and members state go, and it
    /// leaves every group (it would be followed again otherwise). Downloads stay.
    public func unfollow(_ channelId: String) {
        guard isFollowing(channelId) else { return }
        let videoIds = Set((state.recentVideos[channelId] ?? []).map(\.id))
        state.channels.removeAll { $0.id == channelId }
        state.recentVideos[channelId] = nil
        state.fetchedAt[channelId] = nil
        state.nonMemberChannels[channelId] = nil
        state.noMembersPlaylist[channelId] = nil
        state.channelErrors[channelId] = nil
        state.memberAccess = state.memberAccess.filter { !videoIds.contains($0.key) }
        state.groups = state.groups.map { group in
            var group = group
            group.channels.removeAll { $0.id == channelId }
            return group
        }
        store.save(state)
        publish()
    }

    /// Moves a channel just before `target` (nil: to the end), as on the Mac.
    public func moveChannel(_ channelId: String, before target: String?) {
        guard channelId != target, let from = state.channels.firstIndex(where: { $0.id == channelId }) else { return }
        let channel = state.channels.remove(at: from)
        let to = target.flatMap { t in state.channels.firstIndex { $0.id == t } } ?? state.channels.endIndex
        state.channels.insert(channel, at: to)
        store.save(state)
        publish()
    }

    /// SwiftUI's `.onMove`.
    public func moveChannels(fromOffsets source: IndexSet, toOffset destination: Int) {
        var channels = state.channels
        let moving = source.map { channels[$0] }
        let before = destination < channels.count ? channels[destination].id : nil
        channels.removeAll { channel in moving.contains { $0.id == channel.id } }
        var at = before.flatMap { id in channels.firstIndex { $0.id == id } } ?? channels.endIndex
        for channel in moving {
            channels.insert(channel, at: at)
            at += 1
        }
        state.channels = channels
        store.save(state)
        publish()
    }

    // Groups (local, in the same shape as Firestore's shared/phone)

    /// Applies a group edit. Channels a group gains that aren't followed get followed (the Mac's
    /// rule); returns those.
    @discardableResult
    public func editGroups(_ change: ([ChannelGroup]) -> [ChannelGroup]) -> [GroupChannel] {
        state.groups = change(state.groups)
        var seen = Set<String>()
        let missing = state.groups.flatMap(\.channels).filter { !isFollowing($0.id) && seen.insert($0.id).inserted }
        store.save(state)
        publish()
        for channel in missing { follow(ChannelInfo(id: channel.id, title: channel.title)) }
        return missing
    }

    // Switching from the Mac

    /// Keeps the Mac's channels (with their recent videos, so nothing is fetched again right
    /// away) and groups, after what's here already.
    public func adopt(channels: [Channel], groups: [ChannelGroup]) {
        let now = now()
        for channel in channels.sorted(by: { $0.order < $1.order }) {
            if !isFollowing(channel.id) {
                state.channels.append(FollowedChannel(id: channel.id, title: channel.title, handle: channel.handle,
                                                      avatarURL: channel.avatarURL, addedAt: now))
            }
            let recent = channel.recent.map { RecentMerge.normalized($0.video, channel: FollowedChannel(id: channel.id, title: channel.title)) }
            state.recentVideos[channel.id] = RecentMerge.merge(state.recentVideos[channel.id] ?? [], with: recent, now: now, cap: Self.recentPerChannel)
            var times = state.fetchedAt[channel.id] ?? FeedTimes()
            times.uploads = now
            times.streams = now
            state.fetchedAt[channel.id] = times
        }
        var ids = Set(state.groups.map(\.id))
        state.groups += groups.filter { ids.insert($0.id).inserted }
        var seen = Set<String>()
        for channel in state.groups.flatMap(\.channels) where !isFollowing(channel.id) && seen.insert(channel.id).inserted {
            state.channels.append(FollowedChannel(id: channel.id, title: channel.title, addedAt: now))
        }
        store.save(state)
        publish()
    }

    /// Saves and stops (switching to the Mac): standalone.json stays for later.
    public func saveForLater() {
        store.save(state)
        stop()
    }

    private func publish() { onChange?() }

    #if DEBUG
    /// Tests: replaces the state as if read from disk.
    func replaceState(_ change: (inout StandaloneState) -> Void) {
        change(&state)
        store.save(state)
        publish()
    }
    #endif
}
