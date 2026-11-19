import Foundation

/// What one channel's feeds returned during a check.
struct ChannelFetch: Sendable {
    var channel: Channel
    /// The feeds that succeeded, each newest first.
    var sources: [FeedKind: [Video]] = [:]
    var errors: [String] = []
    /// YouTube rejected the cookies for the members feed.
    var authExpired = false
    /// The members feed failed for a reason other than the sign-in or the network
    /// (yt-dlp missing, crashed, unparsable output).
    var membersFailed = false
    /// The members feed was read with accepted cookies.
    var membersSucceeded = false

    /// Fetches the public feed, plus the members feed when `cookiesFile` is given.
    static func fetch(_ channel: Channel, youtube: any YouTubeService, cookiesFile: URL?) async -> ChannelFetch {
        var result = ChannelFetch(channel: channel)
        do {
            result.sources[.uploads] = try await youtube.fetchPublicVideos(channelId: channel.id)
        } catch {
            result.errors.append("\(channel.title): public feed failed: \(error.logDescription)")
        }
        guard let cookiesFile else { return result }
        do {
            let feed = try await youtube.fetchMembersVideos(channelId: channel.id, cookiesFile: cookiesFile)
            // A playlist listed despite rejected cookies is still worth diffing.
            result.sources[.members] = feed.videos
            result.authExpired = feed.cookiesRejected
            result.membersSucceeded = !feed.cookiesRejected
        } catch StowError.authExpired {
            result.authExpired = true
        } catch {
            if !error.isTransient { result.membersFailed = true }
            result.errors.append("\(channel.title): members feed failed: \(error.logDescription)")
        }
        return result
    }

    /// Fetches every channel, at most `maxConcurrent` at a time. Results are in `channels` order.
    static func fetchAll(
        _ channels: [Channel], youtube: any YouTubeService, cookiesFile: URL?, maxConcurrent: Int = 3
    ) async -> [ChannelFetch] {
        await withTaskGroup(of: (Int, ChannelFetch).self) { group in
            var pending = channels.enumerated().makeIterator()
            func addNext() {
                guard let (index, channel) = pending.next() else { return }
                group.addTask { (index, await fetch(channel, youtube: youtube, cookiesFile: cookiesFile)) }
            }
            for _ in 0..<maxConcurrent { addNext() }
            var results: [(Int, ChannelFetch)] = []
            for await result in group {
                results.append(result)
                addNext()
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

extension Error {
    /// Offline or slow: worth reporting only when it keeps happening.
    var isTransient: Bool {
        switch self as? StowError {
        case .network, .timedOut: true
        default: false
        }
    }

    /// One line, bounded length, for the log and CheckResult.errors.
    var logDescription: String {
        let text = (self as? LocalizedError)?.errorDescription ?? localizedDescription
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
}
