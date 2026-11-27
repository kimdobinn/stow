import Foundation
import Observation

/// Seconds watched per day and channel, plus videos finished, kept 90 days on the phone.
@MainActor
@Observable
public final class WatchStats {
    public struct Day: Hashable, Sendable {
        /// The local calendar day, "yyyy-MM-dd".
        public var key: String
        public var secondsByChannel: [String: Int]
        public var finishedByChannel: [String: Int]

        public init(key: String, secondsByChannel: [String: Int], finishedByChannel: [String: Int]) {
            self.key = key
            self.secondsByChannel = secondsByChannel
            self.finishedByChannel = finishedByChannel
        }

        public var seconds: Int { secondsByChannel.values.reduce(0, +) }
        public var finished: Int { finishedByChannel.values.reduce(0, +) }
    }

    /// Bumps on every change, so screens can recompute.
    public private(set) var changes = 0
    @ObservationIgnored private var days: [String: Day]
    @ObservationIgnored private var unsaved = 0
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(directory: URL, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { .now }) {
        file = directory.appending(path: "stats.json")
        self.calendar = calendar
        self.now = now
        days = [:]
        if let data = try? Data(contentsOf: file),
           let root = try? JSONDecoder().decode([String: [String: [String: Int]]].self, from: data) {
            for (key, value) in root {
                days[key] = Day(key: key, secondsByChannel: value["seconds"] ?? [:], finishedByChannel: value["finished"] ?? [:])
            }
        }
    }

    public func addSeconds(_ channelId: String, _ seconds: Int) {
        let key = dayKey(now())
        var day = days[key] ?? Day(key: key, secondsByChannel: [:], finishedByChannel: [:])
        day.secondsByChannel[channelId, default: 0] += seconds
        days[key] = day
        unsaved += seconds
        // A write every half minute of watching is plenty.
        if unsaved >= 30 { save() }
        changes += 1
    }

    public func addFinished(_ channelId: String) {
        let key = dayKey(now())
        var day = days[key] ?? Day(key: key, secondsByChannel: [:], finishedByChannel: [:])
        day.finishedByChannel[channelId, default: 0] += 1
        days[key] = day
        save()
        changes += 1
    }

    public func day(_ date: Date) -> Day {
        let key = dayKey(date)
        return days[key] ?? Day(key: key, secondsByChannel: [:], finishedByChannel: [:])
    }

    public func today() -> Day { day(now()) }

    /// The 7 days ending on `end`'s day (oldest first).
    public func week(ending end: Date? = nil) -> [Day] {
        let end = end ?? now()
        return (0...6).reversed().map { offset in day(calendar.date(byAdding: .day, value: -offset, to: end) ?? end) }
    }

    /// Writes what's not saved yet (going to the background).
    public func flush() { save() }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func save() {
        unsaved = 0
        let cutoff = dayKey(calendar.date(byAdding: .day, value: -90, to: now()) ?? now())
        // "yyyy-MM-dd" sorts like the dates themselves.
        days = days.filter { $0.key >= cutoff }
        let root = days.mapValues { ["seconds": $0.secondsByChannel, "finished": $0.finishedByChannel] }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(root) { try? data.write(to: file, options: .atomic) }
    }
}
