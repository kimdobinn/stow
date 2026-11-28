import Foundation
import Testing
@testable import StowKit

/// A tiny Firestore for videos/: lists and gets what it holds, and a commit that creates a video
/// stamps sentAt with the server's clock (a little after the phone's tap, as the real one does).
final class FakeVideoServer: @unchecked Sendable {
    private let lock = NSLock()
    private var docs: [String: (title: String, sentAt: Date, sentBy: String, watched: Bool)] = [:]
    /// Commits fail with this (status, body) while set.
    var failCommits: (Int, String)? {
        get { lock.withLock { _failCommits } }
        set { lock.withLock { _failCommits = newValue } }
    }
    private var _failCommits: (Int, String)?
    private(set) var commits = 0
    let clockSkew: TimeInterval = 0.3
    /// Answer commits without the server's timestamps.
    var omitsTimes = false

    lazy var server = StubServer { [unowned self] request in self.respond(request) }

    func add(_ id: String, title: String, sentAt: Date, sentBy: String = "mac") {
        lock.withLock { docs[id] = (title, sentAt, sentBy, false) }
    }

    func has(_ id: String) -> Bool { lock.withLock { docs[id] != nil } }
    func watched(_ id: String) -> Bool? { lock.withLock { docs[id]?.watched } }

    private func document(_ id: String) -> String? {
        guard let doc = docs[id] else { return nil }
        let stamp = FirestoreTime.string(from: doc.sentAt)
        return """
            {"name":"projects/stow-test/databases/(default)/documents/videos/\(id)","fields":{
              "title":{"stringValue":"\(doc.title)"},"channelId":{"stringValue":"UCSJ4gkVC6NrvII8umztf0Ow"},
              "sentBy":{"stringValue":"\(doc.sentBy)"},"watched":{"booleanValue":\(doc.watched)},
              "sentAt":{"timestampValue":"\(stamp)"},"updatedAt":{"timestampValue":"\(stamp)"}}}
            """
    }

    private func respond(_ request: StubServer.Request) -> (Int, String) {
        lock.withLock {
            switch request.path {
            case "\(documentsPrefix)/videos":
                let list = docs.keys.sorted().compactMap(document).joined(separator: ",")
                return (200, #"{"documents":[\#(list)]}"#)
            case "\(documentsPrefix)/channels": return (200, "{}")
            case "\(documentsPrefix):runQuery": return (200, "[]")
            case "\(documentsPrefix):commit":
                commits += 1
                if let failure = _failCommits { return failure }
                let writes = request.json["writes"] as? [[String: Any]] ?? []
                let update = writes.first?["update"] as? [String: Any]
                let name = update?["name"] as? String ?? ""
                let fields = update?["fields"] as? [String: Any] ?? [:]
                let id = String(name.split(separator: "/").last ?? "")
                guard name.contains("/videos/") else { return (200, #"{"writeResults":[{}]}"#) }
                if writes.first?["currentDocument"] == nil {
                    // A create: the rules refuse it when the document exists (it would be an update).
                    if docs[id] != nil { return (403, try! fixture("permission-denied.json")) }
                    let stamp = Date.now.addingTimeInterval(clockSkew)
                    let title = ((fields["title"] as? [String: Any])?["stringValue"] as? String) ?? id
                    let watched = ((fields["watched"] as? [String: Any])?["booleanValue"] as? Bool) ?? false
                    docs[id] = (title, stamp, "phone", watched)
                    let text = FirestoreTime.string(from: stamp)
                    if omitsTimes { return (200, #"{"writeResults":[{}]}"#) }
                    return (200, #"{"writeResults":[{"transformResults":[{"timestampValue":"\#(text)"},{"timestampValue":"\#(text)"}]}],"commitTime":"\#(text)"}"#)
                }
                if let watched = (fields["watched"] as? [String: Any])?["booleanValue"] as? Bool { docs[id]?.watched = watched }
                return (200, #"{"writeResults":[{}]}"#)
            default:
                if request.path.hasPrefix("\(documentsPrefix)/videos/") {
                    let id = String(request.path.split(separator: "/").last ?? "")
                    if let doc = document(id) { return (200, doc) }
                }
                return (404, #"{"error":{"code":404,"status":"NOT_FOUND"}}"#)
            }
        }
    }
}

/// Downloads this phone asks for itself (from a search, a channel page or YouTube's feeds).
@MainActor
@Suite struct PhoneRequestTests {
    private let id = "n61ULEU7CO0"
    private let searchJSON = #"{"entries":[{"id":"n61ULEU7CO0","title":"Best of lofi","channel":"Lofi Girl","channel_id":"UCSJ4gkVC6NrvII8umztf0Ow","duration":600}]}"#

    private func paired(_ fake: FakeVideoServer, youtube: FakeYouTube, directory: URL = temporaryDirectory(),
                        defaults: UserDefaults? = nil) -> Repository {
        let defaults = defaults ?? {
            let defaults = freshDefaults()
            defaults.set("stow-test", forKey: "pairedProject")
            defaults.set(Data(repeating: 1, count: 32).base64URLEncodedString, forKey: "pairingKey")
            return defaults
        }()
        return Repository(config: testConfig, youtube: youtube, defaults: defaults, directory: directory,
                          tokenStore: InMemoryTokenStore(validTokens()), network: FixedNetwork(.wifi), session: fake.server.session)
    }

    private func searchAndDownload(_ repository: Repository) async throws {
        _ = try await repository.searchYouTube("lofi")
        repository.download(try #require(repository.item(id)))
        #expect(await eventually { repository.item(id)?.isPlayable == true })
    }

    /// The tester's case: the server's sentAt is a little later than the tap, which used to look
    /// like "sent again" and brought the deleted download back on every poll.
    @Test(arguments: [false, true]) func aDeletedRequestStaysDeleted(omitsTimes: Bool) async throws {
        let fake = FakeVideoServer()
        fake.omitsTimes = omitsTimes
        let youtube = FakeYouTube()
        youtube.searchJSON = searchJSON
        let repository = paired(fake, youtube: youtube)
        #expect(await repository.refresh())
        try await searchAndDownload(repository)
        #expect(await eventually { fake.has(id) })
        #expect(await repository.refresh(full: true))
        #expect(repository.local[id]?.requestedAt == nil)
        repository.deleteDownload(id)
        #expect(await repository.refresh(full: true))
        #expect(await repository.refresh(full: true))
        #expect(repository.local[id]?.state == .deleted)
        #expect(youtube.downloadCalls == [id])
    }

    /// Deleted before any poll saw the server's copy: still stays deleted.
    @Test func deletedBeforeThePollSawItStaysDeleted() async throws {
        let fake = FakeVideoServer()
        let youtube = FakeYouTube()
        youtube.searchJSON = searchJSON
        let repository = paired(fake, youtube: youtube)
        #expect(await repository.refresh())
        try await searchAndDownload(repository)
        #expect(await eventually { fake.has(id) })
        repository.deleteDownload(id)
        #expect(await repository.refresh(full: true))
        #expect(repository.local[id]?.state == .deleted)
        #expect(youtube.downloadCalls == [id])
    }

    /// Sent again from the Mac later: that does download it again.
    @Test func sentAgainFromTheMacDownloadsAgain() async throws {
        let fake = FakeVideoServer()
        let youtube = FakeYouTube()
        youtube.searchJSON = searchJSON
        let repository = paired(fake, youtube: youtube)
        #expect(await repository.refresh())
        try await searchAndDownload(repository)
        #expect(await eventually { fake.has(id) })
        #expect(await repository.refresh(full: true))
        repository.deleteDownload(id)
        fake.add(id, title: "Best of lofi", sentAt: .now.addingTimeInterval(60))
        #expect(await repository.refresh(full: true))
        #expect(await eventually { repository.item(id)?.isPlayable == true })
        #expect(youtube.downloadCalls == [id, id])
    }

    /// The request fails (offline, quota, 5xx): it's filed on a later poll, and the download stays
    /// listed meanwhile, also after a relaunch with the search results gone.
    @Test func aFailedRequestIsFiledLaterAndStaysListed() async throws {
        let fake = FakeVideoServer()
        fake.failCommits = (503, #"{"error":{"code":503,"message":"Unavailable","status":"UNAVAILABLE"}}"#)
        let youtube = FakeYouTube()
        youtube.searchJSON = searchJSON
        let directory = temporaryDirectory()
        let defaults = freshDefaults()
        defaults.set("stow-test", forKey: "pairedProject")
        defaults.set(Data(repeating: 1, count: 32).base64URLEncodedString, forKey: "pairingKey")
        let repository = paired(fake, youtube: youtube, directory: directory, defaults: defaults)
        #expect(await repository.refresh())
        try await searchAndDownload(repository)
        #expect(await eventually { fake.commits >= 1 })
        #expect(!fake.has(id))
        #expect(repository.item(id)?.sent?.sentBy == "phone")
        #expect(repository.downloadIds() == [id])
        // Marked watched while it isn't filed: the request carries it.
        repository.setWatched(id, true)
        #expect(repository.item(id)?.watched == true)

        // A relaunch: no search results, and Firestore still failing.
        let again = paired(fake, youtube: youtube, directory: directory, defaults: defaults)
        again.start()
        #expect(again.downloadIds() == [id])
        #expect(again.item(id)?.isPlayable == true)
        #expect(again.item(id)?.watched == true)
        _ = await again.refresh()
        #expect(again.downloadIds() == [id])

        // Firestore is back: the next poll files it, once.
        fake.failCommits = nil
        #expect(await again.refresh())
        #expect(await eventually { fake.has(id) })
        #expect(fake.watched(id) == true)
        #expect(await eventually { again.local[id]?.requestedAt == nil })
        #expect(await again.refresh(full: true))
        #expect(again.item(id)?.sent?.sentBy == "phone")
        #expect(again.item(id)?.watched == true)
        #expect(again.downloadIds() == [id])
        let commits = fake.commits
        #expect(await again.refresh(full: true))
        #expect(fake.commits == commits)
        #expect(youtube.downloadCalls == [id])
    }

    /// Someone filed the video first: the refused create takes the server's copy.
    @Test func aRefusedRequestTakesTheServersCopy() async throws {
        let fake = FakeVideoServer()
        let youtube = FakeYouTube()
        youtube.searchJSON = searchJSON
        let repository = paired(fake, youtube: youtube)
        #expect(await repository.refresh())
        _ = try await repository.searchYouTube("lofi")
        let item = try #require(repository.item(id))
        let macSentAt = Date.now.addingTimeInterval(-30)
        fake.add(id, title: "Best of lofi", sentAt: macSentAt)
        repository.download(item)
        #expect(await eventually { repository.local[id]?.requestedAt == nil })
        #expect(repository.item(id)?.sent?.sentBy == "mac")
        #expect(abs((repository.local[id]?.sentAt ?? .distantPast).timeIntervalSince(macSentAt)) < 0.01)
    }
}

@MainActor
@Suite struct DemoRelaunchTests {
    private func demo(_ youtube: FakeYouTube, _ directory: URL, _ defaults: UserDefaults) -> Repository {
        Repository(config: nil, youtube: youtube, demo: true, defaults: defaults, directory: directory,
                   tokenStore: InMemoryTokenStore(), network: FixedNetwork(.wifi))
    }

    @Test func aDeletedSampleStaysDeletedAfterARelaunch() async {
        let directory = temporaryDirectory()
        let defaults = freshDefaults()
        let youtube = FakeYouTube()
        let first = demo(youtube, directory, defaults)
        first.start()
        #expect(await eventually { first.item("jNQXAC9IVRw")?.isPlayable == true })
        first.deleteDownload("jNQXAC9IVRw")
        let again = demo(youtube, directory, defaults)
        again.start()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(again.local["jNQXAC9IVRw"]?.state == .deleted)
        #expect(youtube.downloadCalls == ["jNQXAC9IVRw"])
    }

    @Test func aSearchedDownloadIsStillListedAfterARelaunch() async throws {
        let directory = temporaryDirectory()
        let defaults = freshDefaults()
        let youtube = FakeYouTube()
        youtube.searchJSON = #"{"entries":[{"id":"ApTMnGiqY8Y","title":"Charlie bit my finger","channel":"HDCYT","channel_id":"UCHDCYT0000000000000000","duration":75}]}"#
        let first = demo(youtube, directory, defaults)
        first.start()
        _ = try await first.searchYouTube("charlie")
        first.download(try #require(first.item("ApTMnGiqY8Y")))
        #expect(await eventually { first.item("ApTMnGiqY8Y")?.isPlayable == true })
        let again = demo(youtube, directory, defaults)
        again.start()
        #expect(await eventually { again.downloadIds().contains("ApTMnGiqY8Y") })
        #expect(again.item("ApTMnGiqY8Y")?.isPlayable == true)
        #expect(again.item("ApTMnGiqY8Y")?.video.title == "Charlie bit my finger")
        again.deleteDownload("ApTMnGiqY8Y")
        #expect(!again.downloadIds().contains("ApTMnGiqY8Y"))
    }

    /// A download still waiting at relaunch (no search results any more) still downloads.
    @Test func aWaitingRequestStillDownloadsAfterARelaunch() async throws {
        let directory = temporaryDirectory()
        let defaults = freshDefaults()
        let youtube = FakeYouTube()
        youtube.searchJSON = #"{"entries":[{"id":"ApTMnGiqY8Y","title":"Charlie bit my finger","channel":"HDCYT","channel_id":"UCHDCYT0000000000000000","duration":75}]}"#
        let first = Repository(config: nil, youtube: youtube, demo: true, defaults: defaults, directory: directory,
                               tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline))
        first.start()
        _ = try await first.searchYouTube("charlie")
        first.download(try #require(first.item("ApTMnGiqY8Y")))
        let again = demo(youtube, directory, defaults)
        again.start()
        #expect(await eventually { again.item("ApTMnGiqY8Y")?.isPlayable == true })
    }
}

@MainActor
@Suite struct PairingRetryTests {
    private let key = Data((0..<32).map { UInt8($0 * 3) })

    @Test func aUsedCodeSaysSo() async {
        let server = StubServer { request in
            switch request.path {
            case "/v1/accounts:signUp": return (200, #"{"idToken":"id-token-1","refreshToken":"refresh-1","expiresIn":"3600","localId":"phone-uid"}"#)
            default: return (403, try! fixture("permission-denied.json"))
            }
        }
        let repository = Repository(config: testConfig, youtube: FakeYouTube(), defaults: freshDefaults(), directory: temporaryDirectory(),
                                    tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline), session: server.session,
                                    cookieVault: InMemoryCookieVault())
        await repository.pair("stow://pair?p=stow-test&c=\(String(repeating: "c", count: 43))&k=\(key.base64URLEncodedString)")
        #expect(repository.pairState == .unpaired(message: "This pairing code was already used. On the Mac, open Pair a Phone again and scan the new code."))
    }

    @Test func aUsedCodeOfAPhoneTheMacAddedPairs() async {
        let server = StubServer { request in
            switch request.path {
            case "/v1/accounts:signUp": return (200, #"{"idToken":"id-token-1","refreshToken":"refresh-1","expiresIn":"3600","localId":"phone-uid"}"#)
            case "\(documentsPrefix)/members/phone-uid": return (200, #"{"name":"projects/stow-test/databases/(default)/documents/members/phone-uid","fields":{}}"#)
            case "\(documentsPrefix)/videos", "\(documentsPrefix)/channels": return (200, "{}")
            case "\(documentsPrefix):runQuery": return (200, "[]")
            default: return (403, try! fixture("permission-denied.json"))
            }
        }
        let repository = Repository(config: testConfig, youtube: FakeYouTube(), defaults: freshDefaults(), directory: temporaryDirectory(),
                                    tokenStore: InMemoryTokenStore(), network: FixedNetwork(.offline), session: server.session,
                                    cookieVault: InMemoryCookieVault())
        await repository.pair("stow://pair?p=stow-test&c=\(String(repeating: "c", count: 43))&k=\(key.base64URLEncodedString)")
        #expect(repository.pairState == .paired)
    }

    @Test func shortCodesAreNotPairingCodes() {
        #expect(Invite.parse("stow://pair?p=stow-test&c=short&k=abc") == nil)
    }
}
