import Foundation

/// Why a check runs.
public enum CheckTrigger: String, Sendable, Codable {
    case launch, foreground, tick, background, pull, channelAdded, signIn

    /// Runs whatever the schedule says (pull, a new channel, a new sign-in).
    public var isForced: Bool { self == .pull || self == .channelAdded || self == .signIn }
}

/// Which feeds one check reads: a pure function of the trigger and what's due, tested as it is.
public struct CheckPlan: Equatable, Sendable {
    public struct Feeds: Equatable, Sendable {
        public var uploads = true
        public var streams = false
        public var members = false

        public init(uploads: Bool = true, streams: Bool = false, members: Bool = false) {
            self.uploads = uploads
            self.streams = streams
            self.members = members
        }
    }

    /// By channel id, in the order given.
    public var channels: [(id: String, feeds: Feeds)]
    /// YouTube's Home and Subscriptions.
    public var accountFeeds: Bool
    public var history: Bool
    /// Looks up members-only videos' access after the members feeds or Home and Subscriptions.
    public var accessChecks: Bool

    public static func == (a: CheckPlan, b: CheckPlan) -> Bool {
        a.channels.map(\.id) == b.channels.map(\.id) && a.channels.map(\.feeds) == b.channels.map(\.feeds)
            && a.accountFeeds == b.accountFeeds && a.history == b.history && a.accessChecks == b.accessChecks
    }

    public func feeds(_ channelId: String) -> Feeds? { channels.first { $0.id == channelId }?.feeds }

    // The schedule (the Mac's numbers where it has them).
    public static let checkInterval: TimeInterval = 15 * 60
    public static let streamsInterval: TimeInterval = 6 * 3600
    public static let streamsPullInterval: TimeInterval = 3600
    public static let membersInterval: TimeInterval = 60 * 60
    public static let membersPullInterval: TimeInterval = 15 * 60
    public static let feedsInterval: TimeInterval = 20 * 60
    public static let historyInterval: TimeInterval = 15 * 60
    /// A channel whose members feeds are skipped (not a member, or no members playlist) is looked at again after this.
    public static let membersSkip: TimeInterval = 7 * 86_400

    /// What the account allows.
    public struct Account: Equatable, Sendable {
        public var state: AccountState
        public var syncWatched: Bool
        public var pendingMarks: Bool
        public var lastWatchSync: Date?
        public var feedsLoadedAt: Date?

        public init(state: AccountState, syncWatched: Bool = true, pendingMarks: Bool = false,
                    lastWatchSync: Date? = nil, feedsLoadedAt: Date? = nil) {
            self.state = state
            self.syncWatched = syncWatched
            self.pendingMarks = pendingMarks
            self.lastWatchSync = lastWatchSync
            self.feedsLoadedAt = feedsLoadedAt
        }
    }

    /// - Parameters:
    ///   - channels: the channels this check covers (a new channel's seed covers only it).
    ///   - skippedMembers: channels whose members feeds wait (`nonMemberChannels`, `noMembersPlaylist` within a week).
    public static func plan(trigger: CheckTrigger, channels: [String], fetchedAt: [String: FeedTimes],
                            account: Account, skippedMembers: Set<String>, now: Date) -> CheckPlan {
        func due(_ last: Date?, _ interval: TimeInterval) -> Bool {
            guard let last else { return true }
            return now.timeIntervalSince(last) >= interval
        }
        let signedIn = account.state == .signedIn
        let background = trigger == .background
        let planned = channels.map { id -> (id: String, feeds: Feeds) in
            let times = fetchedAt[id] ?? FeedTimes()
            var feeds = Feeds()
            if !background {
                switch trigger {
                case .channelAdded: feeds.streams = true
                case .pull: feeds.streams = due(times.streams, streamsPullInterval)
                default: feeds.streams = due(times.streams, streamsInterval)
                }
                if signedIn && !skippedMembers.contains(id) {
                    switch trigger {
                    case .channelAdded, .signIn: feeds.members = true
                    case .pull: feeds.members = due(times.members, membersPullInterval)
                    default: feeds.members = due(times.members, membersInterval)
                    }
                }
            }
            return (id, feeds)
        }
        let accountFeeds: Bool
        switch trigger {
        case _ where !signedIn: accountFeeds = false
        case .signIn, .pull: accountFeeds = true
        case .launch, .foreground, .tick: accountFeeds = due(account.feedsLoadedAt, feedsInterval)
        case .background, .channelAdded: accountFeeds = false
        }
        let history: Bool
        if !signedIn || !account.syncWatched || trigger == .channelAdded {
            history = false
        } else if trigger == .pull || trigger == .signIn {
            history = true
        } else {
            history = account.pendingMarks || due(account.lastWatchSync, historyInterval)
        }
        let accessChecks = !background && signedIn && (accountFeeds || planned.contains { $0.feeds.members })
        return CheckPlan(channels: planned, accountFeeds: accountFeeds, history: history, accessChecks: accessChecks)
    }

    /// The minute timer and the background task come about every 15 minutes, and a check takes a
    /// while: measured from the end of the last one, the next would come a little early and be
    /// skipped (every 30 minutes in practice). So a check is due 15 minutes after the last one
    /// started, less this.
    public static let dueSlack: TimeInterval = 60

    /// Whether an automatic check (not pull, a new channel's seed or a sign-in) is due: about 15
    /// minutes since the last one started, and no backoff. A check that couldn't reach YouTube
    /// (`offline`) doesn't count.
    public static func isDue(trigger: CheckTrigger, last: CheckRecord?, backoffUntil: Date?, now: Date) -> Bool {
        if trigger.isForced { return true }
        if let backoffUntil, backoffUntil > now { return false }
        guard let last, !last.offline else { return true }
        return now.timeIntervalSince(last.startedAt) >= checkInterval - dueSlack
    }

    /// The channels whose members feeds wait, as of `now`.
    public static func skippedMembers(nonMember: [String: Date], noPlaylist: [String: Date], now: Date) -> Set<String> {
        let recent = (nonMember.merging(noPlaylist) { max($0, $1) }).filter { now.timeIntervalSince($0.value) < membersSkip }
        return Set(recent.keys)
    }

    /// The next backoff after HTTP 429 or a 5xx: 30 minutes, doubling up to 4 hours.
    public static func nextBackoff(previousMinutes: Int) -> Int {
        previousMinutes <= 0 ? 30 : min(previousMinutes * 2, 240)
    }
}
