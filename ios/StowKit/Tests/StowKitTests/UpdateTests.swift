import Foundation
import Testing
@testable import StowKit

@Suite struct AppVersionTests {
    @Test func comparesNumberByNumber() throws {
        func v(_ text: String) throws -> AppVersion { try #require(AppVersion(text)) }
        #expect(try v("0.1.1") > v("0.1.0"))
        #expect(try v("0.10.0") > v("0.9.9"))
        #expect(try v("1.0") > v("0.99.99"))
        #expect(try v("0.2") > v("0.1.9"))
        #expect(try v("0.1") == v("0.1.0"))
        #expect(try v("0.1.0.0") == v("0.1"))
        #expect(try !(v("0.1.0") < v("0.1")))
        #expect(try v("0.1.0.1") > v("0.1"))
        #expect(try v("2") > v("1.99"))
    }

    @Test func readsPrefixesAndSuffixes() throws {
        #expect(AppVersion("v0.8.1")?.parts == [0, 8, 1])
        #expect(AppVersion(" 0.2.0-beta.1 ")?.parts == [0, 2, 0])
        #expect(AppVersion("1.2.3+45")?.parts == [1, 2, 3])
        #expect(AppVersion("0.1.0")?.description == "0.1.0")
    }

    @Test func refusesWhatIsntAVersion() {
        for text in ["", "abc", "1..2", "1.2.", ".1", "1.x", "-1.0", "ios-v0.1.0"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }
}

@Suite struct ReleaseTests {
    /// GitHub's answer on 2026-11-27: ios-v0.1.0 (a pre-release) and Android's v0.6.1 to v0.8.1.
    func realReleases() throws -> [GitHubRelease] {
        try Updates.decode(Data(fixture("github-releases.json").utf8))
    }

    func release(_ tag: String, draft: Bool = false, assets: [String]? = nil, body: String? = nil) -> GitHubRelease {
        let names = assets ?? ["Stow-\(tag.replacingOccurrences(of: "ios-v", with: "")).ipa"]
        return GitHubRelease(
            tagName: tag, name: tag, body: body ?? "Notes for \(tag)", draft: draft, prerelease: true,
            htmlURL: URL(string: "https://github.com/kimdobinn/stow/releases/tag/\(tag)")!, publishedAt: nil,
            assets: names.map {
                .init(name: $0, browserDownloadURL: URL(string: "https://github.com/kimdobinn/stow/releases/download/\(tag)/\($0)")!, size: 100)
            })
    }

    @Test func parsesGitHubsReleases() throws {
        let releases = try realReleases()
        #expect(releases.count == 6)
        let ios = try #require(releases.first)
        #expect(ios.tagName == "ios-v0.1.0")
        #expect(ios.prerelease && !ios.draft)
        #expect(ios.htmlURL.absoluteString == "https://github.com/kimdobinn/stow/releases/tag/ios-v0.1.0")
        #expect(ios.body?.hasPrefix("First iPhone version.") == true)
        #expect(ios.publishedAt == ISO8601DateFormatter().date(from: "2026-11-27T03:32:35Z"))
        #expect(ios.assets.map(\.name) == ["Stow-0.1.0.ipa"])
        #expect(ios.assets.first?.size == 15354292)
        #expect(releases.dropFirst().allSatisfy { $0.tagName.hasPrefix("v") && !$0.prerelease })
    }

    @Test func todaysNewestIsZeroOneZeroNotAndroidsEightOne() throws {
        let latest = try #require(Updates.latest(in: realReleases()))
        #expect(latest.version == "0.1.0")
        #expect(latest.tag == "ios-v0.1.0")
        #expect(latest.ipaURL?.absoluteString == "https://github.com/kimdobinn/stow/releases/download/ios-v0.1.0/Stow-0.1.0.ipa")
        #expect(latest.ipaSize == 15354292)
        #expect(!latest.isNewer(than: "0.1.0"))
        #expect(latest.isNewer(than: "0.0.9"))
    }

    @Test func onlyPublishedIPhoneTagsCount() {
        let releases = [
            release("v0.9.0", assets: ["Stow-0.9.0.apk"]),
            release("mac-v1.2.0", assets: ["Stow-1.2.0.dmg"]),
            release("ios-v0.3.0", draft: true),
            release("ios-v0.2.0"),
            release("ios-vnext"),
            release("ios-v0.1.0"),
            release("iOS-v5.0.0"),
        ]
        #expect(Updates.latest(in: releases)?.version == "0.2.0")
        #expect(Updates.latest(in: releases.filter { !$0.tagName.hasPrefix("ios-") }) == nil)
        #expect(Updates.latest(in: []) == nil)
        #expect(Updates.version(ofTag: "mac-v0.1.0") == nil)
        #expect(Updates.version(ofTag: "ios-v0.10.1")?.parts == [0, 10, 1])
    }

    @Test func highestVersionWinsWhateverTheOrder() {
        let releases = [release("ios-v0.9.0"), release("ios-v0.10.0"), release("ios-v0.2.5")]
        #expect(Updates.latest(in: releases)?.version == "0.10.0")
        #expect(Updates.latest(in: releases.reversed())?.version == "0.10.0")
    }

    @Test func picksTheIPA() {
        let named = release("ios-v0.2.0", assets: ["notes.txt", "Other.ipa", "Stow-0.2.0.ipa"])
        #expect(Updates.ipaAsset(in: named, version: "0.2.0")?.name == "Stow-0.2.0.ipa")
        let renamed = release("ios-v0.2.0", assets: ["notes.txt", "Stow.IPA"])
        #expect(Updates.ipaAsset(in: renamed, version: "0.2.0")?.name == "Stow.IPA")
        let none = release("ios-v0.2.0", assets: ["Stow-0.2.0.apk"])
        #expect(Updates.ipaAsset(in: none, version: "0.2.0") == nil)
        let update = Updates.latest(in: [none])
        #expect(update?.version == "0.2.0")
        #expect(update?.ipaURL == nil)
    }

    @Test func notesAreTrimmed() {
        #expect(Updates.latest(in: [release("ios-v0.2.0", body: "\n- Faster search\n- Fixes\n\n")])?.notes == "- Faster search\n- Fixes")
        let noBody = GitHubRelease(tagName: "ios-v0.2.0", name: nil, body: nil, draft: false, prerelease: true,
                                   htmlURL: URL(string: "https://example.com")!, publishedAt: nil, assets: [])
        #expect(Updates.latest(in: [noBody])?.notes == "")
    }

    @Test func installLinksPreferSideStoreThenAltStoreThenTheReleasePage() throws {
        let update = try #require(Updates.latest(in: [release("ios-v0.2.0")]))
        let ipa = "https://github.com/kimdobinn/stow/releases/download/ios-v0.2.0/Stow-0.2.0.ipa"

        let both = Updates.link(for: update) { _ in true }
        #expect(both.installer == .sideStore)
        #expect(both.url.absoluteString == "sidestore://install?url=\(ipa)")
        // Read back the way SideStore and AltStore read it.
        let components = try #require(URLComponents(url: both.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "install")
        #expect(components.queryItems?.first { $0.name == "url" }?.value == ipa)

        let altStore = Updates.link(for: update) { $0.scheme == "altstore" }
        #expect(altStore.installer == .altStore)
        #expect(altStore.url.absoluteString == "altstore://install?url=\(ipa)")

        let neither = Updates.link(for: update) { _ in false }
        #expect(neither.installer == .browser)
        #expect(neither.url == update.pageURL)

        var noIPA = update
        noIPA.ipaURL = nil
        #expect(Updates.link(for: noIPA) { _ in true }.installer == .browser)
    }

    @Test func installLinkKeepsAQueryInTheIPAURLWhole() throws {
        let ipa = URL(string: "https://example.com/get?file=Stow-0.2.0.ipa&sig=a+b")!
        let link = Updates.installLink(scheme: "sidestore", ipa: ipa)
        let items = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.count == 1)
        #expect(items.first?.value == ipa.absoluteString)
    }
}

@MainActor
@Suite struct UpdateCheckerTests {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    nonisolated static func releasesJSON(_ tags: [String]) -> String {
        let items = tags.map { tag in
            let version = tag.replacingOccurrences(of: "ios-v", with: "")
            return """
            {"tag_name":"\(tag)","name":"Stow for iPhone \(version)","body":"What's new in \(version)","draft":false,"prerelease":true,
             "html_url":"https://github.com/kimdobinn/stow/releases/tag/\(tag)","published_at":"2026-11-28T10:00:00Z",
             "assets":[{"name":"Stow-\(version).ipa","size":123,"browser_download_url":"https://github.com/kimdobinn/stow/releases/download/\(tag)/Stow-\(version).ipa"}]}
            """
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    func checker(_ server: StubServer, version: String = "0.1.0", defaults: UserDefaults, clock: Clock) -> UpdateChecker {
        UpdateChecker(currentVersion: version, url: URL(string: "https://api.github.com/repos/kimdobinn/stow/releases?per_page=100")!,
                      session: server.session, defaults: defaults, now: { clock.now })
    }

    @Test func findsANewerVersionAndAsksGitHubProperly() async throws {
        let server = StubServer { _ in (200, Self.releasesJSON(["ios-v0.1.1", "v0.9.0", "ios-v0.1.0"])) }
        let updates = checker(server, defaults: freshDefaults(), clock: Clock())
        #expect(updates.status == .idle && updates.isDue)
        await updates.check()
        #expect(updates.status == .checked)
        #expect(updates.available?.version == "0.1.1")
        #expect(updates.available?.notes == "What's new in 0.1.1")
        #expect(updates.showsBanner)
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/repos/kimdobinn/stow/releases")
        #expect(request.headers["Accept"] == "application/vnd.github+json")
        #expect(request.headers["Authorization"] == nil)
    }

    @Test func upToDateWhenTheNewestIsInstalled() async {
        let server = StubServer { _ in (200, Self.releasesJSON(["v0.8.1", "ios-v0.1.0"])) }
        let updates = checker(server, defaults: freshDefaults(), clock: Clock())
        await updates.check()
        #expect(updates.status == .checked)
        #expect(updates.latest?.version == "0.1.0")
        #expect(updates.available == nil)
        #expect(!updates.showsBanner)
        // An older release than the one installed (a build from main) isn't an update either.
        let ahead = checker(server, version: "0.2.0", defaults: freshDefaults(), clock: Clock())
        await ahead.check()
        #expect(ahead.available == nil)
    }

    @Test func checksAtMostOnceADay() async {
        let server = StubServer { _ in (200, Self.releasesJSON(["ios-v0.1.0"])) }
        let clock = Clock()
        let defaults = freshDefaults()
        let updates = checker(server, defaults: defaults, clock: clock)
        await updates.checkIfDue()
        #expect(server.requests.count == 1)
        clock.now += 60 * 60
        await updates.checkIfDue()
        #expect(server.requests.count == 1)
        // A relaunch remembers when it checked.
        let relaunched = checker(server, defaults: defaults, clock: clock)
        #expect(relaunched.status == .checked)
        await relaunched.checkIfDue()
        #expect(server.requests.count == 1)
        // Asking in Settings always checks.
        await relaunched.check()
        #expect(server.requests.count == 2)
        clock.now += UpdateChecker.interval + 1
        await relaunched.checkIfDue()
        #expect(server.requests.count == 3)
        // A clock set back doesn't stop the checks.
        clock.now -= 3 * UpdateChecker.interval
        #expect(relaunched.isDue)
    }

    @Test func rememberedUpdateShowsAfterARelaunchWithoutAsking() async {
        let server = StubServer { _ in (200, Self.releasesJSON(["ios-v0.2.0"])) }
        let defaults = freshDefaults()
        let clock = Clock()
        await checker(server, defaults: defaults, clock: clock).check()
        let relaunched = checker(server, defaults: defaults, clock: clock)
        #expect(relaunched.available?.version == "0.2.0")
        #expect(relaunched.available?.ipaURL?.lastPathComponent == "Stow-0.2.0.ipa")
        #expect(relaunched.showsBanner)
        #expect(server.requests.count == 1)
        // Once 0.2.0 is installed, it's no longer an update.
        let updated = checker(server, version: "0.2.0", defaults: defaults, clock: clock)
        #expect(updated.available == nil)
    }

    @Test func bannerClosesPerVersion() async {
        let server = StubServer { _ in (200, Self.releasesJSON(["ios-v0.1.1"])) }
        let defaults = freshDefaults()
        let clock = Clock()
        let updates = checker(server, defaults: defaults, clock: clock)
        await updates.check()
        #expect(updates.showsBanner)
        updates.dismissBanner()
        #expect(!updates.showsBanner)
        #expect(updates.available?.version == "0.1.1")
        #expect(!checker(server, defaults: defaults, clock: clock).showsBanner)
        // A newer version brings it back.
        server.setHandler { _ in (200, Self.releasesJSON(["ios-v0.1.2", "ios-v0.1.1"])) }
        await updates.check()
        #expect(updates.available?.version == "0.1.2")
        #expect(updates.showsBanner)
    }

    @Test func failuresSayWhyAndWaitAnHourBeforeTheNextAutomaticCheck() async {
        let server = StubServer { _ in (403, #"{"message":"API rate limit exceeded"}"#) }
        let clock = Clock()
        let updates = checker(server, defaults: freshDefaults(), clock: clock)
        await updates.checkIfDue()
        #expect(updates.status == .failed("GitHub is busy. Try again later"))
        #expect(updates.lastChecked == nil)
        await updates.checkIfDue()
        #expect(server.requests.count == 1)
        clock.now += UpdateChecker.retryInterval + 1
        server.setHandler { _ in (200, "not json") }
        await updates.checkIfDue()
        #expect(server.requests.count == 2)
        #expect(updates.status == .failed("Couldn't read GitHub's answer"))
        server.setHandler { _ in (500, "") }
        await updates.check()
        #expect(updates.status == .failed("GitHub answered with error 500"))
        server.setHandler { _ in (200, Self.releasesJSON(["ios-v0.1.0"])) }
        await updates.check()
        #expect(updates.status == .checked)
        #expect(updates.lastChecked == clock.now)
    }

    @Test func aFailedCheckKeepsTheUpdateItFoundBefore() async {
        let server = StubServer { _ in (200, Self.releasesJSON(["ios-v0.3.0"])) }
        let updates = checker(server, defaults: freshDefaults(), clock: Clock())
        await updates.check()
        server.setHandler { _ in (502, "") }
        await updates.check()
        #expect(updates.status == .failed("GitHub answered with error 502"))
        #expect(updates.available?.version == "0.3.0")
    }

    @Test func offlineMessages() {
        #expect(UpdateChecker.message(for: URLError(.notConnectedToInternet)) == "No internet connection")
        #expect(UpdateChecker.message(for: URLError(.timedOut)) == "GitHub didn't answer")
        #expect(UpdateChecker.message(for: URLError(.cannotFindHost)) == "Couldn't reach GitHub")
        #expect(UpdateChecker.message(for: UpdateChecker.CheckError.http(429)) == "GitHub is busy. Try again later")
    }
}
