import StowKit
import SwiftUI

/// This week's watching: the total, minutes per day and time per channel.
struct ReportScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(\.stowColors) private var colors
    @Environment(\.channelAvatars) private var avatars

    var body: some View {
        // Read so the figures follow what you watch.
        let _ = repository.stats.changes
        let thisWeek = repository.stats.week()
        let lastWeek = repository.stats.week(ending: Calendar.current.date(byAdding: .day, value: -7, to: .now))
        let report = WeekReport(thisWeek: thisWeek, lastWeek: lastWeek)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.minutes(seconds: report.total))
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(colors.text)
                    Text(report.change)
                        .font(.subheadline)
                        .foregroundStyle(colors.secondaryText)
                }
                .padding(16)
                .accessibilityElement(children: .combine)
                DayBars(days: thisWeek)
                    .frame(height: 150)
                    .padding(.horizontal, 16)
                Text("Minutes per day")
                    .font(.caption)
                    .foregroundStyle(colors.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                SectionHeader("By channel")
                if report.byChannel.isEmpty {
                    EmptyState("Nothing watched this week yet.")
                }
                ForEach(report.byChannel, id: \.channelId) { entry in
                    channelRow(entry, longest: report.channelMax)
                }
            }
            .padding(.bottom, 24)
        }
        .background(colors.background)
        .navigationTitle("Your week")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func channelRow(_ entry: WeekReport.ChannelTime, longest: Int) -> some View {
        let title = repository.channelTitle(entry.channelId).nilIfBlank ?? "Other"
        let detail = [Format.minutes(seconds: entry.seconds), entry.finished > 0 ? Format.count(entry.finished, "video") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ChannelAvatar(url: avatars[entry.channelId], name: title, size: 28)
                // The time goes under the name when both don't fit (large text).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(colors.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(detail).font(.footnote).foregroundStyle(colors.secondaryText).lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(colors.text).lineLimit(2)
                        Text(detail).font(.footnote).foregroundStyle(colors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GeometryReader { proxy in
                Capsule().fill(colors.chip)
                    .overlay(alignment: .leading) {
                        Capsule().fill(colors.accent)
                            .frame(width: proxy.size.width * min(max(Double(entry.seconds) / Double(longest), 0.02), 1))
                    }
            }
            .frame(height: 4)
            .padding(.leading, 38)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
    }
}

/// The week's figures, as Android's ReportScreen works them out.
struct WeekReport {
    struct ChannelTime {
        var channelId: String
        var seconds: Int
        var finished: Int
    }

    let total: Int
    let previous: Int
    let byChannel: [ChannelTime]

    init(thisWeek: [WatchStats.Day], lastWeek: [WatchStats.Day]) {
        total = thisWeek.reduce(0) { $0 + $1.seconds }
        previous = lastWeek.reduce(0) { $0 + $1.seconds }
        var seconds: [String: Int] = [:]
        var finished: [String: Int] = [:]
        for day in thisWeek {
            for (id, value) in day.secondsByChannel { seconds[id, default: 0] += value }
            for (id, value) in day.finishedByChannel { finished[id, default: 0] += value }
        }
        byChannel = seconds.map { ChannelTime(channelId: $0.key, seconds: $0.value, finished: finished[$0.key] ?? 0) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.channelId < $1.channelId }
    }

    /// Compared with the 7 days before.
    var change: String {
        if previous == 0 { return "in the last 7 days" }
        if total <= previous { return "\(Format.minutes(seconds: previous - total)) less than the week before" }
        return "\(Format.minutes(seconds: total - previous)) more than the week before"
    }

    /// The longest bar (at least a minute, so a few seconds don't fill it).
    var channelMax: Int { Swift.max(byChannel.first?.seconds ?? 60, 60) }
}

/// One bar per day, today last (in the accent), with the minutes on top.
private struct DayBars: View {
    let days: [WatchStats.Day]
    @Environment(\.stowColors) private var colors

    var body: some View {
        let most = max(days.map(\.seconds).max() ?? 0, 60)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(days.enumerated()), id: \.element.key) { index, day in
                let isToday = index == days.count - 1
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(day.seconds >= 60 ? "\(day.seconds / 60)" : " ")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(colors.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    GeometryReader { proxy in
                        let fraction = min(max(Double(day.seconds) / Double(most), 0.02), 1)
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .fill(isToday ? colors.accent : colors.secondaryText.opacity(0.45))
                            .frame(height: proxy.size.height * fraction)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    Text(Self.weekday(day.key))
                        .font(.caption2)
                        .foregroundStyle(isToday ? colors.text : colors.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.weekday(day.key, style: .wide)): \(Format.minutes(seconds: day.seconds))")
            }
        }
    }

    /// "Mon" for "2026-11-23".
    static func weekday(_ key: String, style: Date.FormatStyle.Symbol.Weekday = .abbreviated) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return "" }
        return date.formatted(.dateTime.weekday(style))
    }
}

extension String {
    /// nil for an empty or blank string.
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
