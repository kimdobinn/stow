import Foundation
import Testing
@testable import Stow

struct StoreTests {
    let store = Store(directory: temporaryDirectory())

    @Test func missingFilesGiveDefaults() throws {
        #expect(try store.loadSettings() == .default)
        #expect(try store.loadState() == .empty)
        #expect(try store.loadLog().isEmpty)
    }

    @Test func roundTripsWithPrettySortedJSON() throws {
        let channel = Channel(info: ChannelInfo(id: "UCeUP5Kb-EDDplwAi0H02XlA", title: "TQQQ 크레이지", handle: "@TQQQCRAZY",
                                                avatarURL: URL(string: "https://yt3.ggpht.com/a.jpg")))
        let settings = AppSettings(schemaVersion: 1, channels: [channel], checkIntervalMinutes: 15, launchAtLogin: false)
        try store.save(settings)
        #expect(try store.loadSettings() == settings)

        let text = try String(contentsOf: store.settingsFile, encoding: .utf8)
        #expect(text.contains("\"avatarURL\" : \"https://yt3.ggpht.com/a.jpg\""))
        #expect(text.contains("TQQQ 크레이지"))
        let keys = ["\"channels\"", "\"checkIntervalMinutes\"", "\"launchAtLogin\"", "\"schemaVersion\""]
        let offsets = keys.map { text.range(of: $0)!.lowerBound }
        #expect(offsets == offsets.sorted())

        let result = CheckResult(trigger: .manual, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                 finishedAt: Date(timeIntervalSince1970: 1_800_000_005), channelsChecked: 1, newVideos: 1, errors: ["x"])
        let state = AppState(seenVideoIds: ["UCx": ["a", "b"]],
                             inbox: [InboxItem(video: video("a", minutesAgo: 1), foundAt: Date(timeIntervalSince1970: 1_800_000_000))],
                             lastCheck: result)
        try store.save(state)
        #expect(try store.loadState() == state)
        #expect(try String(contentsOf: store.stateFile, encoding: .utf8).contains("\"2027-01-15T08:00:00Z\""))
    }

    @Test func savingSettingsKeepsUnknownKeys() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let json = #"{"alarm": {"time": "07:00", "snooze": 5}, "phoneSync": {"on": true}, "channels": [{"id": "UCeUP5Kb-EDDplwAi0H02XlA", "note": "keep"}, {"id": "UCgone"}]}"#
        try Data(json.utf8).write(to: store.settingsFile)
        var settings = try store.loadSettings()
        settings.channels[0].phone = false
        settings.channels.removeLast()
        settings.alarm.volume = 40
        try store.save(settings)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.settingsFile)) as? [String: Any]
        #expect((saved?["phoneSync"] as? [String: Bool]) == ["on": true])
        let alarm = saved?["alarm"] as? [String: Any]
        #expect(alarm?["time"] as? String == "07:00")
        #expect(alarm?["volume"] as? Int == 40)
        #expect(alarm?["snooze"] as? Int == 5)
        let channels = saved?["channels"] as? [[String: Any]]
        #expect(channels?.count == 1)
        #expect(channels?.first?["note"] as? String == "keep")
        #expect(channels?.first?["phone"] as? Bool == false)
        #expect(try store.loadSettings() == settings)
    }

    @Test func logIsCappedKeepingNewest() throws {
        let entries = (0..<(Store.logLimit + 20)).map { LogEntry(level: .info, message: "\($0)") }
        try store.save(log: entries)
        let loaded = try store.loadLog()
        #expect(loaded.count == Store.logLimit)
        #expect(loaded.last?.message == "\(Store.logLimit + 19)")
    }

    @Test func handEditedFileWithFractionalDatesAndMissingKeysDecodes() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let json = #"{"lastCheck": {"trigger": "manual", "startedAt": "2026-11-19T08:00:00.123Z", "finishedAt": "2026-11-19T08:00:01Z", "channelsChecked": 0, "newVideos": 0, "errors": []}}"#
        try Data(json.utf8).write(to: store.stateFile)
        let state = try store.loadState()
        #expect(state.inbox.isEmpty)
        #expect(state.lastCheck?.channelsChecked == 0)
    }

    @Test func malformedFileThrowsAndCanBeQuarantined() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.settingsFile)
        #expect(throws: (any Error).self) { try store.loadSettings() }
        let moved = try store.quarantine(store.settingsFile)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try store.loadSettings() == .default)
    }
}
