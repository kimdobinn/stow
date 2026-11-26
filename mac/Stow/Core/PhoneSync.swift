import CryptoKit
import Foundation
import Observation

/// What PhoneSync needs from the app (implemented by AppModel).
@MainActor
protocol PhoneSyncHost: AnyObject {
    var phoneState: PhoneSyncState { get }
    /// Changes and saves state.json's phone section.
    func updatePhoneState(_ change: (inout PhoneSyncState) -> Void)
    var phoneChannels: [Channel] { get }
    /// A channel's recent videos (Inbox ones too), newest first.
    func phoneRecentVideos(channelId: String) -> [Video]
    /// False for a members-only video the account's level can't watch, or not checked yet.
    func canSendToPhone(videoId: String, isMembersOnly: Bool) -> Bool
    /// A video from the Inbox or Recent.
    func phoneVideo(id: String) -> Video?
    func isWatched(videoId: String) -> Bool
    /// The phone marked a video watched or unwatched.
    func applyPhoneWatched(_ watched: Bool, videoId: String)
    /// cookies.txt while signed in to YouTube.
    var phoneCookiesFile: URL? { get }
    /// YouTube's Home and Subscriptions for the signed-in account; nil when signed out or failed.
    func phoneAccountFeeds() async -> AccountFeeds?
    /// Channels in the phone's groups: any that aren't followed here yet get added.
    func phoneGroupChannels(_ channels: [GroupChannel])
    /// A pull-to-refresh on the phone: checks every channel now and returns when it's done.
    func phoneRefresh() async
    func logPhone(_ level: LogLevel, _ message: String)
}

/// Keeps the paired phones in step through the user's Firebase project: sends them new videos
/// (Firestore document + FCM push to wake the phone), shares channels, watched status and the
/// encrypted YouTube cookies, and reads back what the phones did. Firestore has no push to the
/// Mac over REST, so the phones' changes are polled every minute.
@MainActor
@Observable
final class PhoneSync {
    static let interval: Duration = .seconds(60)
    static let pairingLifetime: TimeInterval = 10 * 60
    static let sentLimit = 1000
    /// More ids than this don't fit an FCM message comfortably; the phone then reads them all.
    static let pushIdLimit = 50
    /// Recent videos per channel shown on the phone's channel pages.
    static let recentPerChannel = 30
    /// YouTube's Home and Subscriptions are read again this often (each read is two yt-dlp runs).
    static let accountFeedsInterval: TimeInterval = 20 * 60
    static let accountFeedLimit = 150
    /// shared/phone (groups, pull-to-refresh) is read this often, so a refresh on the phone
    /// starts within seconds.
    static let sharedInterval: Duration = .seconds(15)

    enum Connection: Equatable {
        /// No key file yet (Firebase setup not done).
        case notSetUp
        case connecting
        case connected
        case failed(String)
    }

    enum PairingStatus: Equatable {
        case waiting
        case paired(name: String)
        case expired
        case failed(String)
    }

    struct Pairing: Equatable {
        var invite: PairingInvite
        var status: PairingStatus
        var expires: Date
    }

    @ObservationIgnored weak var host: (any PhoneSyncHost)?
    /// Settable for tests.
    @ObservationIgnored var pairingPollInterval: Duration = .seconds(2)
    /// Local changes are batched for this long before syncing.
    @ObservationIgnored var debounce: Duration = .seconds(2)

    private(set) var connection: Connection = .notSetUp
    private(set) var projectId: String?
    private(set) var pairing: Pairing?
    private(set) var isSyncing = false
    /// Why the last sync failed; nil once one succeeds.
    private(set) var lastError: String?

    @ObservationIgnored private let keyFile: URL
    @ObservationIgnored private let pairingKeyFile: URL
    @ObservationIgnored private let makeBackend: (URL) throws -> any PhoneBackend
    @ObservationIgnored private var backend: (any PhoneBackend)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sharedLoop: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var debounced: Task<Void, Never>?
    /// The latest `pushToPhones` send; each waits for the one before, so a run's "ended" never
    /// overtakes its "playing".
    @ObservationIgnored private var pushChain: Task<Void, Never>?
    @ObservationIgnored private var syncsAgain = false
    @ObservationIgnored private var accountFeeds: AccountFeeds?
    @ObservationIgnored private var accountFeedsReadAt: Date?
    /// Fingerprint of the feeds last uploaded.
    @ObservationIgnored private var accountFeedsHash: String?
    /// Reading YouTube's feeds, which happens beside the sync rather than holding it up.
    @ObservationIgnored private(set) var accountFeedsRead: Task<Void, Never>?

    init(keyFile: URL, pairingKeyFile: URL,
         makeBackend: @escaping (URL) throws -> any PhoneBackend = { try FirebaseBackend(keyFile: $0) }) {
        self.keyFile = keyFile
        self.pairingKeyFile = pairingKeyFile
        self.makeBackend = makeBackend
    }

    var members: [PhoneMember] { host?.phoneState.members ?? [] }
    var isPaired: Bool { !members.isEmpty }
    /// The phone's channel groups.
    var groups: [ChannelGroup] { host?.phoneState.groups ?? [] }

    /// Connects (when the key is there) and syncs every minute while a phone is paired.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.connect()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self, self.backend != nil, self.isPaired else { continue }
                await self.sync()
            }
        }
        sharedLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sharedInterval)
                guard let self, self.backend != nil, self.isPaired else { continue }
                await self.readShared()
            }
        }
    }

    // MARK: Groups and pull-to-refresh

    /// Reads shared/phone: takes the phone's groups and answers a pull-to-refresh by checking
    /// every channel and YouTube's feeds, syncing, then marking it handled.
    func readShared() async {
        guard let backend, let host else { return }
        let shared: PhoneShared?
        do {
            shared = try await backend.shared()
        } catch {
            return   // The minute sync reports Firestore trouble.
        }
        guard let shared else { return }
        if shared.groups != host.phoneState.groups {
            host.updatePhoneState { $0.groups = shared.groups }
        }
        host.phoneGroupChannels(shared.groups.flatMap(\.channels))
        guard let requested = shared.refreshRequestedAt, requested > (host.phoneState.refreshHandled ?? .distantPast),
              !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        host.logPhone(.info, "Refreshing for the phone.")
        accountFeedsReadAt = nil
        await host.phoneRefresh()
        await sync()   // Starts reading YouTube's feeds.
        await accountFeedsRead?.value
        await sync()   // Uploads them.
        do {
            try await backend.markRefreshHandled(requestedAt: requested)
            host.updatePhoneState { $0.refreshHandled = requested }
        } catch {
            lastError = error.logDescription
        }
    }

    /// Changes the groups here, on top of the latest from Firestore (the phone may have just
    /// changed them), and saves them for the phones.
    func editGroups(_ change: @escaping (inout [ChannelGroup]) -> Void) {
        guard let host else { return }
        var local = host.phoneState.groups
        change(&local)
        host.updatePhoneState { $0.groups = local }
        guard let backend else { return }
        Task { [weak self] in
            do {
                var groups = try await backend.shared()?.groups ?? local
                change(&groups)
                try await backend.saveGroups(groups)
                self?.host?.updatePhoneState { $0.groups = groups }
                self?.host?.phoneGroupChannels(groups.flatMap(\.channels))
            } catch {
                self?.lastError = error.logDescription
                self?.host?.logPhone(.warning, "Couldn't save the channel groups: \(error.logDescription)")
            }
        }
    }

    func createGroup(name: String, channels: [GroupChannel] = []) {
        let group = ChannelGroup(name: name, channels: channels)
        editGroups { $0.append(group) }
    }

    func renameGroup(id: String, to name: String) {
        editGroups { groups in
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].name = name }
        }
    }

    func deleteGroup(id: String) {
        editGroups { $0.removeAll { $0.id == id } }
    }

    func setChannel(_ channel: GroupChannel, inGroup id: String, _ included: Bool) {
        editGroups { groups in
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
            groups[index].channels.removeAll { $0.id == channel.id }
            if included { groups[index].channels.append(channel) }
        }
    }

    /// A channel removed here leaves every group too (it would be added back otherwise).
    func removeFromGroups(channelId: String) {
        guard groups.contains(where: { $0.channels.contains { $0.id == channelId } }) else { return }
        editGroups { groups in
            for index in groups.indices { groups[index].channels.removeAll { $0.id == channelId } }
        }
    }

    // MARK: Setup

    /// Uses the service-account key at `source` (checked first), copying it into Stow's folder.
    /// Throws when it isn't a usable key.
    func importKey(from source: URL) async throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        _ = try makeBackend(source)
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: keyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        host?.logPhone(.info, "Firebase key added.")
        await connect()
    }

    /// Loads the key and checks that Firestore answers.
    func connect() async {
        guard FileManager.default.fileExists(atPath: keyFile.path) else {
            backend = nil
            projectId = nil
            connection = .notSetUp
            return
        }
        do {
            let backend = try makeBackend(keyFile)
            self.backend = backend
            projectId = backend.projectId
            connection = .connecting
            await sync()
        } catch {
            backend = nil
            connection = .failed(error.logDescription)
        }
    }

    // MARK: Pairing

    /// Shows a QR code for the phone to scan; the phone then files a request under its code.
    func startPairing() {
        guard let backend else { return }
        pairingTask?.cancel()
        let invite: PairingInvite
        do {
            invite = PairingInvite.make(projectId: backend.projectId, key: try PairingKey.loadOrCreate(at: pairingKeyFile))
        } catch {
            pairing = Pairing(invite: PairingInvite(projectId: backend.projectId, code: "", keyBase64URL: ""),
                              status: .failed("Couldn't create the pairing key: \(error.logDescription)"), expires: .now)
            return
        }
        pairing = Pairing(invite: invite, status: .waiting, expires: .now.addingTimeInterval(Self.pairingLifetime))
        pairingTask = Task { [weak self] in await self?.waitForPhone(invite: invite, backend: backend) }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = nil
    }

    private func waitForPhone(invite: PairingInvite, backend: any PhoneBackend) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pairingPollInterval)
            guard !Task.isCancelled, pairing?.invite == invite, let expires = pairing?.expires else { return }
            if Date.now > expires {
                pairing?.status = .expired
                return
            }
            do {
                guard let request = try await backend.takePairingRequest(code: invite.code) else { continue }
                let member = PhoneMember(id: request.uid, name: request.name, fcmToken: request.fcmToken, pairedAt: .now)
                try await backend.addMember(member)
                host?.updatePhoneState { state in
                    state.members.removeAll { $0.id == member.id }
                    state.members.append(member)
                    // The new phone needs the channels and cookies even if they didn't change.
                    state.channelsHash = nil
                    state.cookiesHash = nil
                }
                accountFeedsHash = nil
                host?.logPhone(.info, "Paired with \(member.name).")
                pairing?.status = .paired(name: member.name)
                await sync()
                return
            } catch {
                // Keep waiting; a network hiccup shouldn't end pairing.
                lastError = error.logDescription
            }
        }
    }

    /// Unpairs a phone: it loses access to everything.
    func removeMember(id: String) async {
        guard let backend else { return }
        do {
            try await backend.removeMember(id: id)
            let name = members.first { $0.id == id }?.name ?? "Phone"
            host?.updatePhoneState { $0.members.removeAll { $0.id == id } }
            host?.logPhone(.info, "Unpaired \(name).")
        } catch {
            lastError = error.logDescription
        }
    }

    // MARK: Sending

    /// "Send to Phone".
    func send(videoId: String) {
        guard let host, host.canSendToPhone(videoId: videoId, isMembersOnly: host.phoneVideo(id: videoId)?.isMembersOnly ?? false) else { return }
        enqueue([videoId], reason: .manual)
    }

    func isSent(videoId: String) -> Bool {
        host?.phoneState.sent[videoId] != nil || host?.phoneState.pending.contains { $0.id == videoId } == true
    }

    func download(videoId: String) -> PhoneDownload? {
        host?.phoneState.sent[videoId]?.download
    }

    private func enqueue(_ ids: [String], reason: PhoneSendReason) {
        guard let host, isPaired, !ids.isEmpty else { return }
        host.updatePhoneState { state in
            for id in ids where !state.pending.contains(where: { $0.id == id }) {
                state.pending.append(PhonePendingSend(id: id, reason: reason))
            }
        }
        localChange()
    }

    /// Something the phones see changed here (watched, channels); syncs shortly.
    func localChange() {
        guard backend != nil, isPaired else { return }
        debounced?.cancel()
        debounced = Task { [weak self] in
            guard let delay = self?.debounce else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    // MARK: Sync

    /// Returns once a sync that started after the call has finished.
    func sync() async {
        guard backend != nil, host != nil else { return }
        guard !isSyncing else {
            syncsAgain = true
            while isSyncing { try? await Task.sleep(for: .milliseconds(20)) }
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncsAgain = false
            await runSync()
        } while syncsAgain
    }

    private func runSync() async {
        guard let backend, let host else { return }
        do {
            let members = try await backend.members()
            host.updatePhoneState { $0.members = members }
            connection = .connected
            if !members.isEmpty {
                try await syncChannels(backend, host)
                try await syncCookies(backend, host)
                try await syncAccountFeeds(backend, host)
                try await pullChanges(backend, host)
                try await pushWatched(backend, host)
                try await sendPending(backend, host, members: members)
                host.updatePhoneState { $0.lastSync = .now }
            }
            if lastError != nil { host.logPhone(.info, "Phone sync works again.") }
            lastError = nil
        } catch {
            let message = error.logDescription
            if connection == .connecting { connection = .failed(message) }
            if lastError != message { host.logPhone(.warning, "Phone sync failed: \(message)") }
            lastError = message
        }
    }

    private func syncChannels(_ backend: any PhoneBackend, _ host: any PhoneSyncHost) async throws {
        let channels = host.phoneChannels
        let feeds = channels.map { channel in
            let recent = Array(host.phoneRecentVideos(channelId: channel.id).prefix(Self.recentPerChannel))
            return PhoneChannelFeed(channel: channel, recent: recent,
                                    watched: Set(recent.map(\.id).filter { host.isWatched(videoId: $0) }))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let fingerprint = feeds.map { feed in
            [String(data: (try? encoder.encode(feed.channel)) ?? Data(), encoding: .utf8) ?? ""]
                + feed.recent.map { "\($0.id)|\($0.title)|\(feed.watched.contains($0.id))|\($0.liveStatus.rawValue)|\($0.duration ?? 0)" }
        }
        let hash = Self.fingerprint((try? encoder.encode(fingerprint)) ?? Data())
        guard hash != host.phoneState.channelsHash else { return }
        let ids = channels.map(\.id)
        let removed = host.phoneState.syncedChannelIds.filter { !ids.contains($0) }
        try await backend.saveChannels(feeds, removing: removed)
        host.updatePhoneState {
            $0.channelsHash = hash
            $0.syncedChannelIds = ids
        }
    }

    private func syncCookies(_ backend: any PhoneBackend, _ host: any PhoneSyncHost) async throws {
        guard let file = host.phoneCookiesFile, let cookies = try? Data(contentsOf: file) else { return }
        let hash = Self.fingerprint(cookies)
        guard hash != host.phoneState.cookiesHash else { return }
        let sealed = try PairingKey.loadOrCreate(at: pairingKeyFile).seal(cookies)
        try await backend.saveCookies(sealed: sealed)
        host.updatePhoneState { $0.cookiesHash = hash }
    }

    /// Shares YouTube's own Home and Subscriptions feeds, sealed like the cookies (they say a lot
    /// about the account). They're read every `accountFeedsInterval` in the background and
    /// uploaded at the sync after, when they changed.
    private func syncAccountFeeds(_ backend: any PhoneBackend, _ host: any PhoneSyncHost) async throws {
        if accountFeedsRead == nil, accountFeedsReadAt.map({ Date.now.timeIntervalSince($0) >= Self.accountFeedsInterval }) ?? true {
            accountFeedsReadAt = .now
            accountFeedsRead = Task { [weak self, weak host] in
                let feeds = await host?.phoneAccountFeeds()
                guard let self else { return }
                self.accountFeedsRead = nil
                guard let feeds else { return }
                self.accountFeeds = feeds
                self.localChange()
            }
        }
        guard let read = accountFeeds else { return }
        // Only members-only videos the account's level can watch, with the dates Stow knows.
        func prepared(_ videos: [FeedVideo]) -> [FeedVideo] {
            videos.filter { host.canSendToPhone(videoId: $0.id, isMembersOnly: $0.isMembersOnly) }.map { video in
                var video = video
                if video.timestamp == nil, let date = host.phoneVideo(id: video.id)?.publishedAt {
                    video.timestamp = date.timeIntervalSince1970.rounded()
                }
                return video
            }
        }
        let feeds = AccountFeeds(recommended: prepared(read.recommended), subscriptions: prepared(read.subscriptions),
                                 channelAvatars: read.channelAvatars)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(feeds)
        let hash = Self.fingerprint(data)
        guard hash != accountFeedsHash else { return }
        let sealed = try PairingKey.loadOrCreate(at: pairingKeyFile).seal(data)
        try await backend.saveAccountFeeds(sealed: sealed)
        accountFeedsHash = hash
    }

    /// Applies what the phones changed: watched status and download progress.
    private func pullChanges(_ backend: any PhoneBackend, _ host: any PhoneSyncHost) async throws {
        let changes = try await backend.videoChanges(after: host.phoneState.cursor)
        guard !changes.isEmpty else { return }
        var state = host.phoneState
        var watchedOnPhone: [(id: String, watched: Bool)] = []
        for change in changes {
            var entry = state.sent[change.id]
                ?? PhoneSentVideo(sentAt: .now, reason: .manual, watched: change.watched ?? false)
            if let download = change.download { entry.download = download }
            if let watched = change.watched, watched != entry.watched {
                entry.watched = watched
                if change.updatedBy == "phone" { watchedOnPhone.append((change.id, watched)) }
            }
            state.sent[change.id] = entry
            state.cursor = change.updatedAt
        }
        host.updatePhoneState { $0 = state }
        for (id, watched) in watchedOnPhone where host.isWatched(videoId: id) != watched {
            host.applyPhoneWatched(watched, videoId: id)
        }
    }

    /// Writes watched changes made here (Stow, the alarm, YouTube) to the phones' videos.
    private func pushWatched(_ backend: any PhoneBackend, _ host: any PhoneSyncHost) async throws {
        let changed = host.phoneState.sent.compactMap { id, entry in
            let watched = host.isWatched(videoId: id)
            return watched == entry.watched ? nil : (id, watched)
        }
        guard !changed.isEmpty else { return }
        let watched = Dictionary(changed, uniquingKeysWith: { first, _ in first })
        try await backend.setWatched(watched)
        host.updatePhoneState { state in
            for (id, value) in watched { state.sent[id]?.watched = value }
        }
    }

    private func sendPending(_ backend: any PhoneBackend, _ host: any PhoneSyncHost, members: [PhoneMember]) async throws {
        let pending = host.phoneState.pending
        guard !pending.isEmpty else { return }
        var sentIds: [String] = []
        for reason in [PhoneSendReason.manual, .auto] {
            let videos = pending.filter { $0.reason == reason }.compactMap { host.phoneVideo(id: $0.id) }
            guard !videos.isEmpty else { continue }
            let watched = Set(videos.map(\.id).filter { host.isWatched(videoId: $0) })
            try await backend.sendVideos(videos, reason: reason, watched: watched)
            let now = Date.now
            host.updatePhoneState { state in
                for video in videos {
                    let previous = state.sent[video.id]
                    state.sent[video.id] = PhoneSentVideo(sentAt: now, reason: reason, watched: watched.contains(video.id),
                                                          download: reason == .manual ? nil : previous?.download)
                }
            }
            sentIds += videos.map(\.id)
            let titles = videos.map { "“\($0.title)”" }.joined(separator: ", ")
            host.logPhone(.info, "Sent to phone (\(reason.rawValue)): \(titles)")
        }
        let handled = Set(pending.map(\.id))
        host.updatePhoneState { state in
            state.pending.removeAll { handled.contains($0.id) }
            Self.prune(&state)
        }
        guard !sentIds.isEmpty else { return }
        await wake(members, backend: backend, host: host, ids: sentIds)
    }

    /// FCM to every phone so it starts downloading now. A failed push isn't a failed sync:
    /// the phone also finds the videos the next time it reads Firestore.
    private func wake(_ members: [PhoneMember], backend: any PhoneBackend, host: any PhoneSyncHost, ids: [String]) async {
        let data = ids.count <= Self.pushIdLimit
            ? ["type": "videos", "ids": ids.joined(separator: ",")]
            : ["type": "sync"]
        for member in members {
            guard let token = member.fcmToken else { continue }
            do {
                if try await !backend.push(data, to: token) {
                    host.logPhone(.warning, "\(member.name)'s push token is out of date; it gets the videos when Stow next opens on it.")
                }
            } catch {
                host.logPhone(.warning, "Couldn't wake \(member.name): \(error.logDescription)")
            }
        }
    }

    /// A data message to every paired phone that has a push token, in the background and in call
    /// order (the alarm remote's start and end). Best effort: failures are only logged.
    func pushToPhones(_ data: [String: String]) {
        guard let backend, let host else { return }
        let members = members.filter { $0.fcmToken != nil }
        guard !members.isEmpty else { return }
        let previous = pushChain
        pushChain = Task {
            await previous?.value
            for member in members {
                guard let token = member.fcmToken else { continue }
                do {
                    if try await !backend.push(data, to: token) {
                        host.logPhone(.warning, "\(member.name)'s push token is out of date.")
                    }
                } catch {
                    host.logPhone(.warning, "Couldn't reach \(member.name): \(error.logDescription)")
                }
            }
        }
    }

    /// Forgets the oldest sent videos beyond `sentLimit`.
    private static func prune(_ state: inout PhoneSyncState) {
        guard state.sent.count > sentLimit else { return }
        let keep = state.sent.sorted { $0.value.sentAt > $1.value.sentAt }.prefix(sentLimit)
        state.sent = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
