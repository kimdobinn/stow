import Foundation
import Synchronization

// Value types for the morning alarm. FROZEN: request changes from the architect.
// settings.json's "alarm" object is hand- and AI-edited, so every key decodes tolerantly:
// a missing or malformed value falls back to its default instead of failing the whole file,
// and the replacement is reported through `SettingsIssues`.

/// The settings.json values that tolerant decoding replaced or ignored, so the app can say so.
/// Pass one as `JSONDecoder.userInfo[.settingsIssues]`.
final class SettingsIssues: Sendable {
    private let list = Mutex<[String]>([])

    var messages: [String] { list.withLock { $0 } }

    func add(_ message: String) {
        list.withLock { $0.append(message) }
    }
}

extension CodingUserInfoKey {
    static let settingsIssues = CodingUserInfoKey(rawValue: "stow.settingsIssues")!
}

extension Decoder {
    var settingsIssues: SettingsIssues? { userInfo[.settingsIssues] as? SettingsIssues }
}

enum Weekday: String, Codable, CaseIterable, Comparable, Sendable {
    case mon, tue, wed, thu, fri, sat, sun

    /// `Calendar` numbering: 1 = Sunday … 7 = Saturday.
    var calendarWeekday: Int {
        switch self {
        case .sun: 1
        case .mon: 2
        case .tue: 3
        case .wed: 4
        case .thu: 5
        case .fri: 6
        case .sat: 7
        }
    }

    /// "mon", "Monday", " TUES": at least the first three letters of the English day name.
    init?(name: String) {
        let text = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.count >= 3, let day = Self.allCases.first(where: { $0.fullName.hasPrefix(text) }) else { return nil }
        self = day
    }

    private var fullName: String {
        switch self {
        case .mon: "monday"
        case .tue: "tuesday"
        case .wed: "wednesday"
        case .thu: "thursday"
        case .fri: "friday"
        case .sat: "saturday"
        case .sun: "sunday"
        }
    }

    init?(calendarWeekday: Int) {
        guard let day = Self.allCases.first(where: { $0.calendarWeekday == calendarWeekday }) else { return nil }
        self = day
    }

    /// Monday-first order, as listed in `allCases`.
    static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A wall-clock time of day, stored as "HH:mm" (24-hour).
struct AlarmTime: Codable, Hashable, Comparable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// Accepts "8:00", "08:00", "08:00:00", "08.00" and 12-hour times ("7:30 am", "7pm"); nil for anything else.
    init?(string: String) {
        var text = string.trimmingCharacters(in: .whitespaces).lowercased()
        var isPM: Bool?
        for (suffix, pm) in [("am", false), ("pm", true)] where text.hasSuffix(suffix) {
            isPM = pm
            text = text.dropLast(2).trimmingCharacters(in: .whitespaces)
        }
        let parts = text.split { $0 == ":" || $0 == "." }.map { Int($0) }
        let minimumParts = isPM == nil ? 2 : 1
        guard (minimumParts...3).contains(parts.count), var hour = parts[0],
              let minute = parts.count > 1 ? parts[1] : 0, (0...59).contains(minute) else { return nil }
        if let isPM {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (isPM ? 12 : 0)
        }
        guard (0...23).contains(hour) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    var string: String { String(format: "%02d:%02d", hour, minute) }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let time = AlarmTime(string: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected HH:mm, got \(text)"))
        }
        self = time
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    static func < (lhs: AlarmTime, rhs: AlarmTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

enum AlarmOrder: String, Codable, CaseIterable, Sendable {
    case oldestFirst, newestFirst
}

/// The Bluetooth speaker the alarm plays on, kept awake between alarms.
struct SpeakerSettings: Codable, Equatable, Sendable {
    /// CoreAudio / Bluetooth device name, e.g. "JBL Go 3".
    var name: String
    /// Bluetooth address "40:C1:F6:88:8F:AF"; nil for a speaker that isn't Bluetooth.
    var address: String?
    /// Play a near-silent signal so the speaker doesn't power itself off.
    var keepAlive: Bool
    /// Keep-alive signal level in dBFS (-90…-20).
    var keepAliveLevel: Double

    static let keepAliveLevelRange: ClosedRange<Double> = -90 ... -20
    static let `default` = SpeakerSettings(name: "JBL Go 3", address: "40:C1:F6:88:8F:AF", keepAlive: true, keepAliveLevel: -60)

    init(name: String, address: String?, keepAlive: Bool, keepAliveLevel: Double) {
        self.name = name
        self.address = address
        self.keepAlive = keepAlive
        self.keepAliveLevel = keepAliveLevel
    }

    private enum CodingKeys: String, CodingKey { case name, address, keepAlive, keepAliveLevel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpeakerSettings.default
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? d.name
        // An explicit null (or "") means "not Bluetooth"; only a missing key takes the default.
        if c.contains(.address) {
            address = (try? c.decodeIfPresent(String.self, forKey: .address)).flatMap { $0.isEmpty ? nil : $0 }
        } else {
            address = d.address
        }
        keepAlive = (try? c.decodeIfPresent(Bool.self, forKey: .keepAlive)) ?? d.keepAlive
        let level = (try? c.decodeIfPresent(Double.self, forKey: .keepAliveLevel)) ?? d.keepAliveLevel
        keepAliveLevel = min(max(level, Self.keepAliveLevelRange.lowerBound), Self.keepAliveLevelRange.upperBound)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(address, forKey: .address)
        try c.encode(keepAlive, forKey: .keepAlive)
        try c.encode(keepAliveLevel, forKey: .keepAliveLevel)
    }
}

enum FallbackRuleKind: String, Codable, CaseIterable, Sendable {
    /// The newest video the alarm hasn't played, published within `withinDays`.
    case mostRecentUnplayed
    /// A random video the alarm hasn't played, published within `withinDays`.
    case randomUnplayed
    /// The newest video, even if the alarm already played it.
    case replayLatest

    var usesDays: Bool { self != .replayLatest }
}

/// Picks a video when the Inbox has nothing new for the alarm. Rules are tried in order; the
/// first one that yields a video wins. The pool is every followed channel's recent videos.
/// On disk: {"kind": "mostRecentUnplayed", "channelId": "UC…", "withinDays": 7}.
struct FallbackRule: Codable, Hashable, Sendable {
    var kind: FallbackRuleKind
    /// Nil (or absent) means any followed channel.
    var channelId: String?
    /// Ignored by `replayLatest`.
    var withinDays: Int

    static let defaultDays = 7
    static let daysRange = 1...365

    init(kind: FallbackRuleKind, channelId: String? = nil, withinDays: Int = FallbackRule.defaultDays) {
        self.kind = kind
        self.channelId = channelId
        self.withinDays = withinDays
    }

    private enum CodingKeys: String, CodingKey { case kind, channelId, withinDays }

    /// Throws only for a missing or unknown `kind`; `AlarmSettings` drops such rules.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(FallbackRuleKind.self, forKey: .kind)
        channelId = (try? c.decodeIfPresent(String.self, forKey: .channelId)).flatMap { $0.isEmpty ? nil : $0 }
        let days = (try? c.decodeIfPresent(Int.self, forKey: .withinDays)) ?? Self.defaultDays
        withinDays = min(max(days, Self.daysRange.lowerBound), Self.daysRange.upperBound)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(channelId, forKey: .channelId)
        if kind.usesDays { try c.encode(withinDays, forKey: .withinDays) }
    }
}

/// settings.json "alarm".
struct AlarmSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var time: AlarmTime
    /// Sorted Monday first, no duplicates. Empty means the alarm never fires.
    var days: [Weekday]
    var maxVideos: Int
    var order: AlarmOrder
    /// Output device volume, 0…100, set right before playing.
    var volume: Int
    /// Longer videos are skipped.
    var maxDurationMinutes: Int
    var fallbackRules: [FallbackRule]
    var speaker: SpeakerSettings
    /// Output used when the speaker isn't available, matched by name ("Mi monitor"); then the
    /// Mac's built-in speakers, then the system default output.
    var fallbackOutput: String

    static let maxVideosRange = 1...10
    static let volumeRange = 0...100
    static let maxDurationRange = 1...600

    static let `default` = AlarmSettings(
        enabled: true, time: AlarmTime(hour: 8, minute: 0), days: [.mon, .tue, .wed, .thu, .fri],
        maxVideos: 3, order: .oldestFirst, volume: 80, maxDurationMinutes: 60,
        fallbackRules: [FallbackRule(kind: .mostRecentUnplayed, withinDays: 7), FallbackRule(kind: .replayLatest)],
        speaker: .default, fallbackOutput: "Mi monitor")

    init(enabled: Bool, time: AlarmTime, days: [Weekday], maxVideos: Int, order: AlarmOrder, volume: Int,
         maxDurationMinutes: Int, fallbackRules: [FallbackRule], speaker: SpeakerSettings, fallbackOutput: String) {
        self.enabled = enabled
        self.time = time
        self.days = Array(Set(days)).sorted()
        self.maxVideos = maxVideos
        self.order = order
        self.volume = volume
        self.maxDurationMinutes = maxDurationMinutes
        self.fallbackRules = fallbackRules
        self.speaker = speaker
        self.fallbackOutput = fallbackOutput
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, time, days, maxVideos, order, volume, maxDurationMinutes, fallbackRules, speaker, fallbackOutput
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlarmSettings.default
        let issues = decoder.settingsIssues
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T, shown: @autoclosure () -> String) -> T {
            do {
                return try c.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                issues?.add("alarm.\(key.stringValue) has a value Stow can't read; using \(shown()).")
                return fallback
            }
        }
        func clamped(_ key: CodingKeys, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            min(max(value(key, fallback, shown: String(fallback)), range.lowerBound), range.upperBound)
        }
        // An unreadable switch turns the alarm off rather than on: better silent than unwanted.
        if (try? c.decodeNil(forKey: .enabled)) ?? true {
            enabled = d.enabled
        } else if let flag = Self.flag(c, .enabled) {
            enabled = flag
        } else {
            enabled = false
            issues?.add("alarm.enabled isn't true or false; the alarm is off until it is.")
        }
        time = value(.time, d.time, shown: d.time.string)
        // Unknown day names are dropped; a value that isn't a list of strings falls back to the default.
        if let names = value(.days, nil as [String]?, shown: "mon–fri") {
            let dropped = names.filter { Weekday(name: $0) == nil }
            if !dropped.isEmpty {
                issues?.add("alarm.days: ignored " + dropped.map { "\"\($0)\"" }.joined(separator: ", ")
                    + " (use mon, tue, wed, thu, fri, sat, sun).")
            }
            days = Array(Set(names.compactMap(Weekday.init(name:)))).sorted()
        } else {
            days = d.days
        }
        maxVideos = clamped(.maxVideos, d.maxVideos, Self.maxVideosRange)
        order = value(.order, d.order, shown: d.order.rawValue)
        volume = clamped(.volume, d.volume, Self.volumeRange)
        maxDurationMinutes = clamped(.maxDurationMinutes, d.maxDurationMinutes, Self.maxDurationRange)
        // A rule with an unknown kind is dropped; the others are kept in order.
        if let rules = value(.fallbackRules, nil as [LossyRule]?, shown: "the default rules") {
            fallbackRules = rules.compactMap(\.rule)
            if fallbackRules.count < rules.count {
                issues?.add("alarm.fallbackRules: ignored a rule without a known kind "
                    + "(\(FallbackRuleKind.allCases.map(\.rawValue).joined(separator: ", "))).")
            }
        } else {
            fallbackRules = d.fallbackRules
        }
        speaker = value(.speaker, d.speaker, shown: "the default speaker")
        fallbackOutput = value(.fallbackOutput, d.fallbackOutput, shown: "\"\(d.fallbackOutput)\"")
    }

    /// true/false, also "yes"/"no", "on"/"off" and 1/0; nil for anything else.
    private static func flag(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let flag = try? c.decode(Bool.self, forKey: key) { return flag }
        if let number = try? c.decode(Int.self, forKey: key), number == 0 || number == 1 { return number == 1 }
        switch (try? c.decode(String.self, forKey: key))?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    private struct LossyRule: Decodable {
        var rule: FallbackRule?
        init(from decoder: Decoder) throws { rule = try? FallbackRule(from: decoder) }
    }
}

/// What started an alarm run.
enum AlarmTrigger: String, Codable, Sendable {
    case scheduled
    /// "Test alarm now".
    case test
}

enum AlarmOutcome: String, Codable, Sendable {
    /// Still in progress (written when the first video starts, so a crash can't replay it).
    case running
    /// At least one video started.
    case played
    /// Streaming failed (or nothing to play); the built-in alarm sound played instead.
    case alarmSound
    /// The Mac woke more than 10 minutes after the alarm time.
    case skippedLate
    /// The user stopped it before anything played.
    case stopped
    /// Nothing could make a sound.
    case failed
}

/// state.json "lastAlarmRun".
struct AlarmRunRecord: Codable, Equatable, Sendable {
    var trigger: AlarmTrigger
    var scheduledFor: Date
    var startedAt: Date
    var endedAt: Date?
    /// Videos that started playing, in order.
    var videoIds: [String]
    /// The fallback rule that picked the videos; nil when they came from the Inbox.
    var fallbackRule: FallbackRule?
    /// Name of the output device used.
    var output: String?
    var outcome: AlarmOutcome
    var error: String?
}

/// A video ready for the player, with its duration from the prep step.
struct PlayableVideo: Hashable, Sendable {
    var video: Video
    var duration: TimeInterval?
}

/// What the player reports while it runs. The stream ends right after `.exited`.
enum PlayerEvent: Equatable, Sendable {
    /// Playlist entry `index` (0-based) started playing (first frame / audio after loading).
    case started(index: Int, videoId: String)
    /// Playback left a video (next, end of file, stop). `position` is the furthest point reached,
    /// counting SponsorBlock skips as watched.
    case videoEnded(videoId: String, position: TimeInterval, duration: TimeInterval?)
    /// A SponsorBlock segment was skipped.
    case skippedSegment(videoId: String, category: String, from: TimeInterval, to: TimeInterval)
    /// An entry couldn't be loaded (yt-dlp failed, unavailable); the player moves on.
    case loadFailed(videoId: String, message: String)
    case exited(PlayerExit)
}

enum PlayerExit: Equatable, Sendable {
    /// The playlist played to the end.
    case finished
    /// `stop()` was called or the user quit mpv (q / closed the window).
    case stopped
    /// mpv crashed, couldn't start or the IPC connection was lost.
    case failed(String)
}

enum AudioTransport: String, Codable, Sendable {
    case builtIn, bluetooth, displayPort, hdmi, usb, airPlay, virtual, other
}

/// A CoreAudio output device.
struct AudioOutput: Hashable, Identifiable, Sendable {
    /// CoreAudio device UID (stable across reconnects; mpv takes it as "coreaudio/<uid>").
    var uid: String
    var name: String
    var transport: AudioTransport
    /// The current system default output.
    var isDefault: Bool

    var id: String { uid }

    /// The output for `speaker`: a Bluetooth output whose UID contains the speaker's address
    /// (CoreAudio uses "40-C1-F6-88-8F-AF:output"), else one named like it.
    static func matching(_ speaker: SpeakerSettings, in outputs: [AudioOutput]) -> AudioOutput? {
        if let address = speaker.address.map(normalizedAddress), !address.isEmpty,
           let output = outputs.first(where: { normalizedAddress($0.uid).contains(address) }) {
            return output
        }
        return named(speaker.name, in: outputs)
    }

    /// Exact name (ignoring case and surrounding spaces), else the first name containing it.
    static func named(_ name: String, in outputs: [AudioOutput]) -> AudioOutput? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        return outputs.first { $0.name.lowercased() == wanted } ?? outputs.first { $0.name.lowercased().contains(wanted) }
    }

    /// Uppercase hex digits only, so "40:c1:f6…" and "40-C1-F6…" compare equal.
    static func normalizedAddress(_ text: String) -> String {
        String(text.uppercased().filter(\.isHexDigit))
    }
}

/// A paired Bluetooth device that can play audio.
struct BluetoothAudioDevice: Hashable, Identifiable, Sendable {
    /// "40:C1:F6:88:8F:AF" (uppercase, colon-separated).
    var address: String
    var name: String
    var isConnected: Bool

    var id: String { address }
}

// MARK: UI-facing alarm status (produced by Core/Alarm, shown by UI/Alarm)

enum AlarmPhase: Equatable, Sendable {
    case idle
    /// The prep step before the alarm time (speaker, feeds, video details).
    case preparing(scheduledFor: Date)
    /// Output chosen and volume set; waiting for the first video to start.
    case starting(output: String?)
    /// `index` is 0-based.
    case playing(index: Int, count: Int, video: Video)
    /// Streaming failed; the built-in alarm sound is looping.
    case alarmSound(reason: String)

    /// True from prep until the run ends; "Stop" applies.
    var isActive: Bool { self != .idle }
}

/// What the alarm would play right now (planner dry-run from state, no yt-dlp).
struct AlarmPreview: Equatable, Sendable {
    /// In play order. Durations are unknown until prep, so a video may still be skipped then.
    var videos: [Video]
    /// The fallback rule that picked `videos`; nil when they are new Inbox videos or there are none.
    var fallbackRule: FallbackRule?

    static let empty = AlarmPreview(videos: [], fallbackRule: nil)
}

struct SpeakerStatus: Equatable, Sendable {
    /// IOBluetooth reports the speaker connected (always false for a speaker without an address).
    var bluetoothConnected: Bool
    /// The speaker's CoreAudio output exists, so the alarm can play on it.
    var outputAvailable: Bool
    var keepAliveRunning: Bool

    static let unknown = SpeakerStatus(bluetoothConnected: false, outputAvailable: false, keepAliveRunning: false)
}
