import Foundation

/// Picks the alarm's videos: new Inbox videos of morning channels first, then the fallback rules.
/// Pure apart from the injected video-details lookup; randomness comes from the passed generator.
enum AlarmPlanner {
    /// At most this many videos are looked up with yt-dlp per run, so prep stays short. Each later
    /// round with candidates keeps up to `batchSize` of them (more in all when there are many
    /// rules), so rejected Inbox videos piling up can't starve the fallback rules.
    static let maxLookups = 12
    /// Looked up together (the details service runs 3 at a time).
    static let batchSize = 3
    static let watchedFraction = 0.9

    /// Candidates tried together: the Inbox (up to `maxVideos`), then each fallback rule (one video).
    struct Round: Equatable {
        /// Nil for the Inbox round.
        var rule: FallbackRule?
        var candidates: [Video]
        var limit: Int
    }

    struct Plan: Equatable {
        var videos: [PlayableVideo]
        var fallbackRule: FallbackRule?
        /// Candidates dropped after their details were checked, with why.
        var skipped: [Skip]
    }

    struct Skip: Equatable {
        var video: Video
        var reason: String
    }

    static func rounds(settings: AlarmSettings, channels: [Channel], state: AppState, now: Date,
                       using generator: inout some RandomNumberGenerator) -> [Round] {
        let inbox = Round(rule: nil, candidates: inboxCandidates(settings: settings, channels: channels, state: state),
                          limit: settings.maxVideos)
        return [inbox] + settings.fallbackRules.map { rule in
            Round(rule: rule, candidates: candidates(for: rule, channels: channels, state: state, now: now, using: &generator),
                  limit: 1)
        }
    }

    /// Inbox videos of channels with `morning` on that the alarm hasn't played and nobody watched, in `settings.order`.
    /// Undated videos (members feed) count as published when they were found.
    static func inboxCandidates(settings: AlarmSettings, channels: [Channel], state: AppState) -> [Video] {
        let morning = Set(channels.filter(\.morning).map(\.id))
        let played = Set(state.alarmPlayedIds).union(state.watchedIds)
        let items = state.inbox.enumerated().filter { _, item in
            morning.contains(item.video.channelId) && !played.contains(item.id) && isStreamable(item.video)
                && (!item.video.isMembersOnly || state.memberAccess[item.id]?.canWatch == true)
        }
        let sorted = items.sorted { lhs, rhs in
            let (a, b) = (lhs.element.video.publishedAt ?? lhs.element.foundAt, rhs.element.video.publishedAt ?? rhs.element.foundAt)
            if a != b { return settings.order == .oldestFirst ? a < b : a > b }
            return lhs.offset < rhs.offset
        }
        return sorted.map(\.element.video)
    }

    /// The rule's candidates, best first. The pool is the recent videos of the rule's channel
    /// (if followed) or, for any channel, of every channel with `morning` on.
    static func candidates(for rule: FallbackRule, channels: [Channel], state: AppState, now: Date,
                           using generator: inout some RandomNumberGenerator) -> [Video] {
        let pool = poolChannels(for: rule, channels: channels)
            .flatMap { state.recentVideos[$0] ?? [] }
            .filter { isStreamable($0) && (!$0.isMembersOnly || state.memberAccess[$0.id]?.canWatch == true) }
        let newestFirst = pool.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        let played = Set(state.alarmPlayedIds).union(state.watchedIds)
        let cutoff = now.addingTimeInterval(-Double(rule.withinDays) * 86_400)
        let unplayedRecent = newestFirst.filter { video in
            guard let date = video.publishedAt else { return false }
            return !played.contains(video.id) && date >= cutoff
        }
        switch rule.kind {
        case .mostRecentUnplayed: return unplayedRecent
        case .randomUnplayed: return unplayedRecent.shuffled(using: &generator)
        case .replayLatest: return newestFirst
        }
    }

    private static func poolChannels(for rule: FallbackRule, channels: [Channel]) -> [String] {
        if let id = rule.channelId { return channels.contains { $0.id == id } ? [id] : [] }
        return channels.filter(\.morning).map(\.id)
    }

    /// Past streams (hours long) aren't alarm material either.
    private static func isStreamable(_ video: Video) -> Bool {
        video.liveStatus != .live && video.liveStatus != .upcoming && video.liveStatus != .wasLive
    }

    /// What the alarm would play now: the first round with candidates, unchecked.
    static func preview(_ rounds: [Round]) -> AlarmPreview {
        guard let round = rounds.first(where: { !$0.candidates.isEmpty }) else { return .empty }
        return AlarmPreview(videos: Array(round.candidates.prefix(round.limit)), fallbackRule: round.rule)
    }

    /// The preview as a plan with unknown durations, for when the details lookup can't finish in time.
    static func unchecked(_ rounds: [Round]) -> Plan {
        let preview = preview(rounds)
        return Plan(videos: preview.videos.map { PlayableVideo(video: $0, duration: nil) },
                    fallbackRule: preview.fallbackRule, skipped: [])
    }

    /// Checks candidates round by round, in batches, until a round yields videos.
    static func plan(_ rounds: [Round], maxDurationMinutes: Int,
                     details: ([String]) async -> [String: VideoDetails]) async -> Plan {
        var checked: [String: VideoDetails] = [:]
        var skipped: [Skip] = []
        var lookups = 0
        for (number, round) in rounds.enumerated() {
            let reserved = rounds.dropFirst(number + 1).reduce(0) { $0 + min(batchSize, $1.candidates.count) }
            let budget = lookups + max(maxLookups - lookups - reserved, batchSize, round.limit)
            var picked: [PlayableVideo] = []
            var index = round.candidates.startIndex
            while picked.count < round.limit, index < round.candidates.endIndex {
                let unchecked = round.candidates[index...].map(\.id).filter { checked[$0] == nil }
                let size = min(max(round.limit - picked.count, batchSize), budget - lookups)
                let batch = Array(unchecked.prefix(max(size, 0)))
                if !batch.isEmpty {
                    lookups += batch.count
                    let found = await details(batch)
                    for id in batch {
                        checked[id] = found[id] ?? VideoDetails(id: id, duration: nil, liveStatus: .unknown,
                                                                isPlayable: false, error: "no details")
                    }
                }
                // Take checked candidates in order; stop at one that couldn't be looked up (budget spent).
                let start = index
                while index < round.candidates.endIndex, picked.count < round.limit,
                      let info = checked[round.candidates[index].id] {
                    let video = round.candidates[index]
                    index += 1
                    if let reason = rejection(info, maxDurationMinutes: maxDurationMinutes) {
                        if !skipped.contains(where: { $0.video.id == video.id }) { skipped.append(Skip(video: video, reason: reason)) }
                    } else if !picked.contains(where: { $0.video.id == video.id }) {
                        picked.append(PlayableVideo(video: video, duration: info.duration))
                    }
                }
                if index == start { break }
            }
            if !picked.isEmpty { return Plan(videos: picked, fallbackRule: round.rule, skipped: skipped) }
        }
        return Plan(videos: [], fallbackRule: nil, skipped: skipped)
    }

    /// Why a video can't be played by the alarm; nil when it can.
    static func rejection(_ details: VideoDetails, maxDurationMinutes: Int) -> String? {
        if !details.isPlayable { return "not playable (\(details.error ?? "unknown error"))" }
        if details.liveStatus == .live || details.liveStatus == .upcoming { return "live or upcoming" }
        if let duration = details.duration, duration > Double(maxDurationMinutes) * 60 {
            return "longer than \(maxDurationMinutes) min (\(Int(duration / 60)) min)"
        }
        return nil
    }

    /// Played to at least 90% (SponsorBlock skips count as watched).
    static func isWatched(position: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return position >= duration * watchedFraction
    }
}

/// SplitMix64: a small seedable generator, so random fallback picks are reproducible (tests) and
/// the Up next preview matches what the alarm will pick that day.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// Seeded by the local day of `date`.
    init(day date: Date, calendar: Calendar) {
        self.init(seed: UInt64(max(0, calendar.startOfDay(for: date).timeIntervalSince1970)))
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
