import Foundation
import StowKit
import Testing
import UIKit
@testable import Stow

/// The update button's link, in the app: canOpenURL answers only for schemes the app declares.
@MainActor
@Suite struct UpdateLinkTests {
    @Test func declaresSideStoreAndAltStoreSchemes() {
        let schemes = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        #expect(schemes.contains("sidestore"))
        #expect(schemes.contains("altstore"))
    }

    @Test func withNeitherInstalledItOpensTheReleasePage() {
        // The simulator has neither SideStore nor AltStore.
        let update = AppUpdate(version: "9.9.9", tag: "ios-v9.9.9", notes: "",
                               pageURL: URL(string: "https://github.com/kimdobinn/stow/releases/tag/ios-v9.9.9")!,
                               ipaURL: URL(string: "https://github.com/kimdobinn/stow/releases/download/ios-v9.9.9/Stow-9.9.9.ipa")!)
        let link = Updates.link(for: update) { UIApplication.shared.canOpenURL($0) }
        #expect(link.installer == .browser)
        #expect(link.url == update.pageURL)
    }

    @Test func theInstalledVersionIsReadable() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        #expect(version.flatMap(AppVersion.init) != nil)
    }
}
