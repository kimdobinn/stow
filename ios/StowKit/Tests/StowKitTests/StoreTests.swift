import Foundation
import Testing
@testable import StowKit

@MainActor
@Suite struct PrefsTests {
    @Test func recentSearchesAreLatestFirstWithoutRepeats() {
        let defaults = freshDefaults()
        let prefs = Prefs(defaults: defaults)
        prefs.addRecentSearch("  lofi  ")
        prefs.addRecentSearch("rick astley")
        prefs.addRecentSearch("LOFI")
        // The same search in other letters moves to the top, as typed the last time.
        #expect(prefs.recentSearches == ["LOFI", "rick astley"])
        prefs.addRecentSearch("   ")
        prefs.addRecentSearch("two\nlines")
        #expect(prefs.recentSearches == ["two lines", "LOFI", "rick astley"])
        prefs.removeRecentSearch("LOFI")
        #expect(prefs.recentSearches == ["two lines", "rick astley"])
        // Kept across launches.
        #expect(Prefs(defaults: defaults).recentSearches == ["two lines", "rick astley"])
    }

    @Test func atMostTwentyRecentSearches() {
        let prefs = Prefs(defaults: freshDefaults())
        for n in 1...25 { prefs.addRecentSearch("search \(n)") }
        #expect(prefs.recentSearches.count == 20)
        #expect(prefs.recentSearches.first == "search 25")
        #expect(prefs.recentSearches.last == "search 6")
    }

    @Test func defaultsAndPersistence() {
        let defaults = freshDefaults()
        let prefs = Prefs(defaults: defaults)
        #expect(prefs.wifiOnly)
        #expect(prefs.downloadQuality == .p1080)
        #expect(prefs.theme == .system)
        #expect(!prefs.autoplay && !prefs.calm && !prefs.grayscale)
        #expect(prefs.playbackSpeed == 1)
        prefs.setWifiOnly(false)
        prefs.downloadQuality = .p720
        prefs.theme = .paper
        prefs.calm = true
        prefs.playbackSpeed = 1.5
        prefs.downloadSort = .longest
        prefs.setWatchedHere("aaaaaaaaaaa", true)
        let again = Prefs(defaults: defaults)
        #expect(!again.wifiOnly)
        #expect(again.downloadQuality == .p720)
        #expect(again.theme == .paper)
        #expect(again.calm)
        #expect(again.playbackSpeed == 1.5)
        #expect(again.downloadSort == .longest)
        #expect(again.watchedHere == ["aaaaaaaaaaa"])
    }

    @Test func qualitiesThisBuildCantDownloadFallBack() {
        let defaults = freshDefaults()
        defaults.set("best", forKey: "downloadQuality")
        #expect(Prefs(defaults: defaults).downloadQuality == .p1080)
        let prefs = Prefs(defaults: defaults)
        prefs.downloadQuality = .p1440
        #expect(prefs.downloadQuality == .p1080)
    }

    @Test func pairingKey() {
        let prefs = Prefs(defaults: freshDefaults())
        #expect(prefs.pairingKey == nil && prefs.pairedProject == nil)
        let key = Data((0..<32).map { UInt8(255 - $0) })
        prefs.savePairing(projectId: "stow-test", keyBase64URL: key.base64URLEncodedString)
        #expect(prefs.pairingKey == key)
        #expect(prefs.pairedProject == "stow-test")
        prefs.clearPairing()
        #expect(prefs.pairingKey == nil && prefs.pairedProject == nil)
    }

    @Test func demoModeFromTheArgumentOrAFile() throws {
        let directory = temporaryDirectory()
        #expect(!Demo.isEnabled(arguments: ["Stow"], directory: directory))
        #expect(Demo.isEnabled(arguments: ["Stow", "-demo"], directory: directory))
        try Data().write(to: directory.appending(path: "demo"))
        #expect(Demo.isEnabled(arguments: ["Stow"], directory: directory))
    }
}

@MainActor
@Suite struct LocalStoreTests {
    @Test func keepsStateAcrossLaunchesWithRelativeFileNames() throws {
        let directory = temporaryDirectory()
        let store = LocalStore(directory: directory)
        store.update("aaaaaaaaaaa") { _ in LocalVideo(id: "aaaaaaaaaaa", state: .downloaded, fileName: "aaaaaaaaaaa.mp4", sizeBytes: 10,
                                                      durationMs: 5000, positionMs: 1000, sentAt: Date(timeIntervalSince1970: 100)) }
        try Data("x".utf8).write(to: store.downloadsDirectory.appending(path: "aaaaaaaaaaa.mp4"))
        let again = LocalStore(directory: directory)
        #expect(again["aaaaaaaaaaa"]?.state == .downloaded)
        #expect(again["aaaaaaaaaaa"]?.sentAt == Date(timeIntervalSince1970: 100))
        #expect(again.fileURL(for: "aaaaaaaaaaa")?.lastPathComponent == "aaaaaaaaaaa.mp4")
        #expect(again.storageUsedBytes() == 1)
        let excluded = try again.downloadsDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
        again.deleteFiles(for: "aaaaaaaaaaa")
        #expect(again.fileURL(for: "aaaaaaaaaaa") == nil)
        again.update("aaaaaaaaaaa") { _ in nil }
        #expect(LocalStore(directory: directory).videos.isEmpty)
    }
}

@MainActor
@Suite struct PlaylistAndStatsTests {
    @Test func playlists() {
        let directory = temporaryDirectory()
        let store = PlaylistStore(directory: directory)
        let first = store.create("  ", firstVideo: "a")
        #expect(first.name == "Playlist")
        let second = store.create("Talks")
        #expect(store.playlists.map(\.id) == [second.id, first.id])
        store.add(first.id, videoId: "b")
        store.add(first.id, videoId: "c")
        store.add(first.id, videoId: "b")
        #expect(store.playlist(first.id)?.videoIds == ["a", "b", "c"])
        store.move(first.id, videoId: "c", by: -1)
        store.move(first.id, videoId: "a", by: -1)
        #expect(store.playlist(first.id)?.videoIds == ["a", "c", "b"])
        store.remove(first.id, videoId: "a")
        store.rename(second.id, to: "  Lectures ")
        #expect(PlaylistStore(directory: directory).playlists.map(\.name) == ["Lectures", "Playlist"])
        #expect(PlaylistStore(directory: directory).playlist(first.id)?.videoIds == ["c", "b"])
        store.delete(second.id)
        #expect(store.playlists.count == 1)
    }

    @Test func watchStatsByDayAndChannel() {
        let directory = temporaryDirectory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = Date(timeIntervalSince1970: 1_795_770_000)
        let stats = WatchStats(directory: directory, calendar: calendar, now: { today })
        stats.addSeconds("UCa", 20)
        stats.addSeconds("UCb", 15)
        stats.addFinished("UCa")
        #expect(stats.today().seconds == 35)
        #expect(stats.today().key == "2026-11-27")
        #expect(stats.today().finishedByChannel == ["UCa": 1])
        let week = stats.week()
        #expect(week.count == 7)
        #expect(week.last?.key == "2026-11-27")
        #expect(week.first?.key == "2026-11-21")
        // Saved: a finished video writes at once.
        let again = WatchStats(directory: directory, calendar: calendar, now: { today })
        #expect(again.today().seconds == 35)
    }
}
