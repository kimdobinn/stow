import Foundation
import Observation

/// Single source of truth for the UI. All mutations persist immediately.
@MainActor
@Observable
final class AppModel {
    static let maxConcurrentChannels = 3
    static let inboxLimit = 300
    /// Videos kept per channel for the Inbox's "Recent" feed.
    static let recentPerChannel = 30
    static let minimumCheckIntervalMinutes = 5
    /// Checks with errors in a row before notifying, so a brief outage stays quiet.
    static let failureNotifyStreak = 3
    static let alarmPlayedLimit = 500
    static let watchedLimit = 2000
    /// A settings.json this fresh that doesn't decode may be half-written; it's read again later.
    static let settingsSettleTime: TimeInterval = 2

    /// In settings.json order.
    var channels: [Channel] { settings.channels }
    /// Newest first.
    var inbox: [InboxItem] { state.inbox }
    /// Every channel's recent videos that aren't in the Inbox, newest first.
    var recentVideos: [Video] {
        channels.flatMap { recentVideos(channelId: $0.id) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    /// One channel's recent videos that aren't in the Inbox, newest first. Dismissing an Inbox
    /// video moves it here.
    func recentVideos(channelId: String) -> [Video] {
        let inboxIds = Set(state.inbox.map(\.id))
        return (state.recentVideos[channelId] ?? [])
            .filter { !inboxIds.contains($0.id) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }
    var lastCheck: CheckResult? { state.lastCheck }
    private(set) var signInState: SignInState = .unknown
    private(set) var isChecking = false
    /// Newest first, capped.
    private(set) var log: [LogEntry] = []
    private(set) var launchAtLogin = false

    private var settings = AppSettings.default
    private var state = AppState.empty

    /// The morning alarm (Core/Alarm). The UI uses it through AppModel+Alarm.swift.
    @ObservationIgnored let alarm: AlarmController

    @ObservationIgnored private let youtube: any YouTubeService
    @ObservationIgnored private let account: any AccountService
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let notifier: any UserNotifying
    @ObservationIgnored private let cookiesFile: URL
    @ObservationIgnored private var scheduler: CheckScheduler?
    @ObservationIgnored private var scheduledMinutes: Int?
    /// A check requested while another was running; it runs right after.
    @ObservationIgnored private var pendingTrigger: CheckTrigger?
    /// Bumped by sign-in and sign-out, so a check that started before one doesn't overwrite its outcome.
    @ObservationIgnored private var authGeneration = 0
    /// settings.json's modification date when last read or written, to pick up hand edits.
    @ObservationIgnored private var settingsStamp: Date?

    convenience init(youtube: any YouTubeService, account: any AccountService, alarmServices: AlarmServices) {
        self.init(youtube: youtube, account: account, store: Store(), notifier: Notifier(),
                  cookiesFile: AppPaths.cookiesFile, alarmServices: alarmServices)
    }

    /// With inert alarm services, for tests, previews and the self-test.
    convenience init(youtube: any YouTubeService, account: any AccountService, store: Store, notifier: any UserNotifying,
                     cookiesFile: URL) {
        self.init(youtube: youtube, account: account, store: store, notifier: notifier,
                  cookiesFile: cookiesFile, alarmServices: .inert)
    }

    init(youtube: any YouTubeService, account: any AccountService, store: Store, notifier: any UserNotifying,
         cookiesFile: URL, alarmServices: AlarmServices) {
        self.youtube = youtube
        self.account = account
        self.store = store
        self.notifier = notifier
        self.cookiesFile = cookiesFile
        alarm = AlarmController(services: alarmServices)
        alarm.host = self
    }

    /// Called once at launch: loads JSON files, applies launch-at-login, requests
    /// notification permission, refreshes sign-in state, starts the check scheduler and the
    /// alarm, and runs a first check.
    func start() {
        load()
        applyLoginItem(settings.launchAtLogin)
        scheduleChecks()
        alarm.start()
        Task {
            if !(await notifier.requestAuthorization()) {
                record(.warning, "Notifications are off for Stow (System Settings › Notifications).")
            }
        }
        Task { await check(.launch) }
    }

    /// Reads the JSON files. An unreadable file is renamed aside and replaced by defaults.
    func load() {
        let savedLog = read(store.logFile, store.loadLog) ?? []
        log += savedLog.reversed()
        settings = loadSettings() ?? .default
        settingsStamp = store.modificationDate(of: store.settingsFile)
        // Write the defaults so a fresh install has a settings.json to hand-edit.
        if settingsStamp == nil { updateSettings { _ in } }
        state = read(store.stateFile, store.loadState) ?? .empty
    }

    // MARK: Checking

    /// Checks every channel now, or right after the check that is already running.
    func checkNow() async {
        await check(.manual)
    }

    /// While a check runs, further requests are merged into one that runs right after it,
    /// since the running check may predate a sign-in or a settings edit.
    func check(_ trigger: CheckTrigger) async {
        guard !isChecking else {
            pendingTrigger = trigger
            return
        }
        isChecking = true
        defer { isChecking = false }
        var next: CheckTrigger? = trigger
        while let current = next {
            await runCheck(current)
            next = pendingTrigger
            pendingTrigger = nil
        }
    }

    private func runCheck(_ trigger: CheckTrigger) async {
        let startedAt = Date.now
        reloadSettingsIfEdited()

        let generation = authGeneration
        let refreshed = await account.refresh()
        if generation == authGeneration { applyRefreshed(refreshed) }

        let checked = channels
        let fetches = await ChannelFetch.fetchAll(
            checked, youtube: youtube,
            cookiesFile: refreshed == .signedIn ? cookiesFile : nil,
            maxConcurrent: Self.maxConcurrentChannels)
        let found = apply(fetches)
        handleAuth(fetches, generation: generation)

        let fetchErrors = fetches.flatMap(\.errors)
        let authErrors = signInState == .expired ? [StowError.authExpired.logDescription] : []
        let result = CheckResult(
            trigger: trigger, startedAt: startedAt, finishedAt: .now,
            channelsChecked: checked.count, newVideos: found.count, errors: authErrors + fetchErrors)
        state.lastCheck = result
        trackFailures(fetchErrors)
        saveState()
        logCheck(result, found: found)

        notifier.notifyNewVideos(found)
        if let failure = fetches.first(where: \.membersFailed)?.errors.last {
            notifier.notifyProblem(title: "Members-only check is failing", body: failure)
        }
    }

    /// Notifies once checks have failed `failureNotifyStreak` times in a row (e.g. the RSS feeds
    /// are down), and logs when they recover.
    private func trackFailures(_ errors: [String]) {
        guard let first = errors.first else {
            if state.failedCheckStreak >= Self.failureNotifyStreak { record(.info, "Checks are working again.") }
            state.failedCheckStreak = 0
            return
        }
        state.failedCheckStreak += 1
        if state.failedCheckStreak >= Self.failureNotifyStreak {
            notifier.notifyProblem(
                title: "New-video checks are failing",
                body: "\(state.failedCheckStreak) checks in a row had errors. \(first)")
        }
    }

    /// Diffs fetched feeds against seen ids, updates state and returns the videos added to the Inbox.
    private func apply(_ fetches: [ChannelFetch]) -> [Video] {
        var found: [Video] = []
        for fetch in fetches where !fetch.sources.isEmpty {
            // The channel may have been removed while its feeds were loading.
            guard let channel = channels.first(where: { $0.id == fetch.channel.id }) else { continue }
            let sources = fetch.sources.mapValues { $0.map { normalized($0, channel: channel) } }
            let diff = VideoDiffer.diff(
                sources: sources, seen: state.seenVideoIds[channel.id],
                checkedFeeds: Set(state.checkedFeeds[channel.id] ?? []))
            state.seenVideoIds[channel.id] = diff.seenVideoIds
            state.recentVideos[channel.id] = Self.mergeRecent(
                state.recentVideos[channel.id] ?? [], with: sources.values.flatMap { $0 })
            state.checkedFeeds[channel.id] = FeedKind.allCases.filter(diff.checkedFeeds.contains)
            found += diff.newVideos
        }
        return addToInbox(found)
    }

    /// Fresh feed entries replace stored ones (titles change); videos that dropped out of a feed
    /// stay until the cap pushes them out.
    private static func mergeRecent(_ stored: [Video], with fetched: [Video]) -> [Video] {
        var byId = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for video in fetched { byId[video.id] = video }
        return Array(byId.values
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .prefix(recentPerChannel))
    }

    /// Uses the channel's (hand-editable) title and id, whatever the feed reported.
    private func normalized(_ video: Video, channel: Channel) -> Video {
        var video = video
        video.channelId = channel.id
        video.channelTitle = channel.title
        return video
    }

    private func addToInbox(_ videos: [Video]) -> [Video] {
        var ids = Set(state.inbox.map(\.id))
        // Undated videos (members feed) were only just found, so they sort as newest.
        let added = videos
            .sorted { ($0.publishedAt ?? .distantFuture) > ($1.publishedAt ?? .distantFuture) }
            .filter { ids.insert($0.id).inserted }
        let foundAt = Date.now
        state.inbox = Array((added.map { InboxItem(video: $0, foundAt: foundAt) } + state.inbox).prefix(Self.inboxLimit))
        return added
    }

    /// Applies what the web data store says. `.expired` sticks until a members feed accepts the
    /// cookies again or the user signs in or out.
    private func applyRefreshed(_ refreshed: SignInState) {
        switch (signInState, refreshed) {
        case (.expired, _):
            break
        case (.signedIn, .signedOut):
            // Nobody signed out here, so YouTube ended the session (it clears LOGIN_INFO).
            markExpired("YouTube ended the saved sign-in; members-only videos can't be checked.")
        default:
            signInState = refreshed
        }
    }

    private func handleAuth(_ fetches: [ChannelFetch], generation: Int) {
        guard generation == authGeneration else { return }
        if fetches.contains(where: \.authExpired) {
            markExpired("YouTube rejected the saved sign-in; members-only videos can't be checked reliably.")
        } else if signInState == .expired, fetches.contains(where: \.membersSucceeded) {
            signInState = .signedIn
            record(.info, "YouTube sign-in works again.")
        }
    }

    private func markExpired(_ message: String) {
        guard signInState != .expired else { return }
        signInState = .expired
        record(.error, message)
        notifier.notifyProblem(
            title: "YouTube sign-in expired",
            body: "Members-only videos can't be checked until you sign in again in Stow Settings › Account.")
    }

    private func logCheck(_ result: CheckResult, found: [Video]) {
        let seconds = result.finishedAt.timeIntervalSince(result.startedAt).formatted(.number.precision(.fractionLength(1)))
        var entries = [LogEntry(
            level: result.isOK ? .info : .warning,
            message: "Check (\(result.trigger.rawValue)): \(result.channelsChecked) channels, \(result.newVideos) new, \(result.errors.count) errors, \(seconds)s")]
        entries += found.map { LogEntry(level: .info, message: Self.describeNew($0)) }
        entries += result.errors.map { LogEntry(level: .error, message: $0) }
        record(entries)
    }

    private static func describeNew(_ video: Video) -> String {
        "\(video.channelTitle): new\(video.isMembersOnly ? " members-only" : "") video “\(video.title)” (\(video.id))"
    }

    // MARK: Channels

    /// Resolves and adds a channel, then seeds it (2 newest -> Inbox, rest seen).
    /// Throws `StowError` (e.g. `.channelAlreadyAdded`, `.channelNotFound`).
    @discardableResult
    func addChannel(input: String) async throws -> Channel {
        let info: ChannelInfo
        do {
            info = try await youtube.resolveChannel(input: input.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            record(.warning, "Couldn't add “\(input)”: \(error.logDescription)")
            throw error
        }
        reloadSettingsIfEdited()
        if let existing = channels.first(where: { $0.id == info.id }) {
            throw StowError.channelAlreadyAdded(existing.title)
        }
        let channel = Channel(info: info)
        updateSettings { $0.channels.append(channel) }
        record(.info, "Added channel \(channel.title) (\(channel.id)).")
        await seed([channel])
        return channel
    }

    /// Adds the picked subscriptions (skipping ones already added) and seeds each.
    func addSubscriptions(_ picked: [ChannelInfo]) async {
        reloadSettingsIfEdited()
        var ids = Set(channels.map(\.id))
        let added = picked.filter { ids.insert($0.id).inserted }.map { Channel(info: $0) }
        guard !added.isEmpty else { return }
        updateSettings { $0.channels += added }
        record(.info, "Added \(added.count) channels from subscriptions: \(added.map(\.title).joined(separator: ", ")).")
        await seed(added)
    }

    /// Fetches newly added channels so the first-add rule puts their 2 newest videos in the Inbox.
    private func seed(_ added: [Channel]) async {
        let generation = authGeneration
        let fetches = await ChannelFetch.fetchAll(
            added, youtube: youtube,
            cookiesFile: signInState == .signedIn ? cookiesFile : nil,
            maxConcurrent: Self.maxConcurrentChannels)
        let found = apply(fetches)
        handleAuth(fetches, generation: generation)
        saveState()
        var entries = [LogEntry(level: .info, message: "Seeded (\(CheckTrigger.channelAdded.rawValue)) \(added.count) channels: \(found.count) videos to the Inbox")]
        entries += fetches.flatMap(\.errors).map { LogEntry(level: .warning, message: $0) }
        record(entries)
    }

    func removeChannel(id: String) {
        guard let channel = channels.first(where: { $0.id == id }) else { return }
        updateSettings { $0.channels.removeAll { $0.id == id } }
        // Forgetting seen ids means re-adding the channel applies the first-add rule again.
        state.seenVideoIds[id] = nil
        state.checkedFeeds[id] = nil
        state.recentVideos[id] = nil
        state.inbox.removeAll { $0.video.channelId == id }
        saveState()
        record(.info, "Removed channel \(channel.title) (\(id)).")
    }

    /// Moves a channel to just before `target` (or to the end when `target` is nil). The channel
    /// order is shared by the Inbox's Recent rows and the Channels list.
    func moveChannel(id: String, before target: String?) {
        guard id != target else { return }
        updateSettings { settings in
            guard let from = settings.channels.firstIndex(where: { $0.id == id }) else { return }
            let channel = settings.channels.remove(at: from)
            let to = target.flatMap { t in settings.channels.firstIndex(where: { $0.id == t }) } ?? settings.channels.endIndex
            settings.channels.insert(channel, at: to)
        }
    }

    func setMorning(_ on: Bool, channelId: String) {
        updateChannel(channelId) { $0.morning = on }
    }

    func setPhone(_ on: Bool, channelId: String) {
        updateChannel(channelId) { $0.phone = on }
    }

    private func updateChannel(_ id: String, _ change: (inout Channel) -> Void) {
        updateSettings { settings in
            if let index = settings.channels.firstIndex(where: { $0.id == id }) { change(&settings.channels[index]) }
        }
    }

    // MARK: Account

    /// The signed-in user's subscriptions for the picker. Throws `.notSignedIn`.
    func loadSubscriptions() async throws -> [ChannelInfo] {
        do {
            return try await account.fetchSubscriptions()
        } catch {
            if case StowError.notSignedIn = error { applyRefreshed(.signedOut) }
            record(.warning, "Couldn't load subscriptions: \(error.logDescription)")
            throw error
        }
    }

    func signIn() async {
        guard await account.signIn() else {
            record(.info, "Sign-in window closed without signing in.")
            return
        }
        authGeneration += 1
        signInState = .signedIn
        record(.info, "Signed in to YouTube.")
        await check(.signIn)
    }

    func signOut() async {
        await account.signOut()
        authGeneration += 1
        signInState = .signedOut
        record(.info, "Signed out of YouTube.")
    }

    // MARK: Inbox

    /// Removes one item from the Inbox (mark as seen).
    func dismissInbox(videoId: String) {
        state.inbox.removeAll { $0.id == videoId }
        saveState()
    }

    func dismissAllInbox() {
        state.inbox.removeAll()
        saveState()
    }

    // MARK: Alarm

    var alarmSettings: AlarmSettings { settings.alarm }
    var lastAlarmRun: AlarmRunRecord? { state.lastAlarmRun }

    /// Saves right away; the alarm re-plans. Sliders should call this when editing ends.
    func updateAlarmSettings(_ change: (inout AlarmSettings) -> Void) {
        updateSettings { change(&$0.alarm) }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        updateSettings { $0.launchAtLogin = on }
        applyLoginItem(on)
    }

    /// settings.json is the source of truth, so a hand edit of launchAtLogin applies at next launch.
    private func applyLoginItem(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
        } catch {
            record(.error, "Couldn't \(on ? "enable" : "disable") launch at login: \(error.logDescription)")
        }
        if on, LoginItem.needsApproval {
            record(.warning, "Approve Stow in System Settings › General › Login Items to launch it at login.")
        }
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: Persistence

    private func read<T>(_ file: URL, _ load: () throws -> T) -> T? {
        do {
            return try load()
        } catch {
            let moved = try? store.quarantine(file)
            let message = "Couldn't read \(file.lastPathComponent): \(error.logDescription). "
                + "Saved it as \(moved?.lastPathComponent ?? "?") and continued with defaults."
            record(.error, message)
            notifier.notifyProblem(title: "Stow couldn't read \(file.lastPathComponent)", body: message)
            return nil
        }
    }

    /// Picks up edits made to settings.json while the app is running.
    private func reloadSettingsIfEdited() {
        let stamp = store.modificationDate(of: store.settingsFile)
        guard stamp != settingsStamp else { return }
        if let stamp, Date.now.timeIntervalSince(stamp) < Self.settingsSettleTime, (try? store.loadSettings()) == nil { return }
        // A broken edit is moved aside by `read`; keep the settings we have rather than defaults.
        if let edited = loadSettings() {
            settings = edited
            record(.info, "Reloaded settings.json after it was edited.")
            if scheduler != nil { scheduleChecks() }
            alarm.settingsDidChange()
        }
        settingsStamp = store.modificationDate(of: store.settingsFile)
    }

    /// settings.json, reporting values that were replaced by defaults or ignored.
    private func loadSettings() -> AppSettings? {
        let issues = SettingsIssues()
        let loaded = read(store.settingsFile) { try store.loadSettings(issues: issues) }
        if !issues.messages.isEmpty {
            let message = "settings.json: " + issues.messages.joined(separator: " ")
            record(.warning, message)
            notifier.notifyProblem(title: "Some settings in settings.json couldn't be used", body: message)
        }
        return loaded
    }

    /// (Re)starts the scheduler when the check interval changed.
    private func scheduleChecks() {
        let minutes = max(Self.minimumCheckIntervalMinutes, settings.checkIntervalMinutes)
        guard minutes != scheduledMinutes else { return }
        scheduledMinutes = minutes
        scheduler?.stop()
        scheduler = CheckScheduler(interval: .seconds(minutes * 60)) { [weak self] trigger in
            await self?.check(trigger)
        }
        scheduler?.start()
    }

    private func updateSettings(_ change: (inout AppSettings) -> Void) {
        reloadSettingsIfEdited()
        change(&settings)
        do {
            try store.save(settings)
        } catch {
            record(.error, "Couldn't save settings.json: \(error.logDescription)")
        }
        settingsStamp = store.modificationDate(of: store.settingsFile)
        alarm.settingsDidChange()
    }

    private func saveState() {
        do {
            try store.save(state)
        } catch {
            record(.error, "Couldn't save state.json: \(error.logDescription)")
        }
    }

    private func record(_ level: LogLevel, _ message: String) {
        record([LogEntry(level: level, message: message)])
    }

    /// `entries` in chronological order.
    private func record(_ entries: [LogEntry]) {
        log = Array((entries.reversed() + log).prefix(Store.logLimit))
        // A failing log write is only reported in the in-memory log, to avoid recursion.
        do {
            try store.save(log: log.reversed())
        } catch {
            log.insert(LogEntry(level: .error, message: "Couldn't save log.json: \(error.logDescription)"), at: 0)
        }
    }
}

extension AppModel: AlarmHost {
    func currentSettings() -> AppSettings {
        reloadSettingsIfEdited()
        return settings
    }

    var currentState: AppState { state }

    var playbackCookiesFile: URL? {
        guard signInState != .signedOut, FileManager.default.fileExists(atPath: cookiesFile.path) else { return nil }
        return cookiesFile
    }

    func refreshForAlarm() async {
        await check(.alarm)
        // A check that was already running queued this one and returned at once.
        while isChecking { try? await Task.sleep(for: .milliseconds(500)) }
    }

    func recordAlarmRun(_ run: AlarmRunRecord, watchedIds: [String]) {
        state.lastAlarmRun = run
        if run.trigger == .scheduled {
            state.lastScheduledAlarm = max(state.lastScheduledAlarm ?? run.scheduledFor, run.scheduledFor)
        }
        // A test run only uses up the videos it played to the end, so it doesn't take the morning's.
        let used = run.trigger == .scheduled ? run.videoIds : watchedIds
        state.alarmPlayedIds = Self.prepending(used, to: state.alarmPlayedIds, limit: Self.alarmPlayedLimit)
        state.watchedIds = Self.prepending(watchedIds, to: state.watchedIds, limit: Self.watchedLimit)
        let played = Set(used)
        state.inbox.removeAll { played.contains($0.id) }
        saveState()
    }

    func logAlarm(_ level: LogLevel, _ message: String) {
        record(level, message)
    }

    func notifyAlarmProblem(title: String, body: String) {
        notifier.notifyProblem(title: title, body: body)
    }

    /// `ids` first (in their order), then the rest of `list` without duplicates, capped.
    private static func prepending(_ ids: [String], to list: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array((ids + list).filter { seen.insert($0).inserted }.prefix(limit))
    }
}
