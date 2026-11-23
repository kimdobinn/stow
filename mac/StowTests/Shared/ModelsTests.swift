import Foundation
import Testing
@testable import Stow

struct ModelsTests {
    @Test func settingsDecodeFillsDefaults() throws {
        let json = #"{"channels": [{"id": "UC-XMoeMXbYrMlvmyLSwDd3g"}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.checkIntervalMinutes == 30)
        #expect(settings.launchAtLogin)
        let channel = try #require(settings.channels.first)
        #expect(channel.title == channel.id)
        #expect(channel.morning)
    }

    @Test func emptyStateDecodes() throws {
        let state = try JSONDecoder().decode(AppState.self, from: Data("{}".utf8))
        #expect(state == .empty)
    }
}
