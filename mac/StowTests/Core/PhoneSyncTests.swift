import CryptoKit
import Foundation
import Security
import Synchronization
import Testing
@testable import Stow

/// Firestore in memory, as the Mac's service account sees it.
final class FakePhoneBackend: PhoneBackend {
    let projectId = "stow-test"
    let members = Mutex<[PhoneMember]>([])
    let pairingRequests = Mutex<[String: PairingRequest]>([:])
    let channels = Mutex<[String: Channel]>([:])
    let videos = Mutex<[String: [String: String]]>([:])
    let cookies = Mutex<Data?>(nil)
    let changes = Mutex<[PhoneVideoChange]>([])
    let pushes = Mutex<[(token: String, data: [String: String])]>([])
    let failure = Mutex<StowError?>(nil)
    /// A push whose `state` is this takes a moment to go out.
    let slowPushState = Mutex<String?>(nil)

    private func check() throws {
        if let error = failure.withLock({ $0 }) { throw error }
    }

    func members() async throws -> [PhoneMember] {
        try check()
        return members.withLock { $0 }
    }

    func takePairingRequest(code: String) async throws -> PairingRequest? {
        try check()
        return pairingRequests.withLock { $0.removeValue(forKey: code) }
    }

    func addMember(_ member: PhoneMember) async throws { members.withLock { $0.append(member) } }
    func removeMember(id: String) async throws { members.withLock { $0.removeAll { $0.id == id } } }

    let feeds = Mutex<[String: PhoneChannelFeed]>([:])
    let channelChangeList = Mutex<[PhoneChannelChange]>([])

    func saveChannels(_ saved: [PhoneChannelFeed], removing: [String]) async throws {
        try check()
        channels.withLock { channels in
            for feed in saved { channels[feed.channel.id] = feed.channel }
            for id in removing { channels[id] = nil }
        }
        feeds.withLock { feeds in
            for feed in saved { feeds[feed.channel.id] = feed }
            for id in removing { feeds[id] = nil }
        }
    }

    func channelChanges(after cursor: String?) async throws -> [PhoneChannelChange] {
        try check()
        return channelChangeList.withLock { all in all.filter { cursor == nil || $0.updatedAt > cursor! } }
    }

    func sendVideos(_ sent: [Video], reason: PhoneSendReason, watched: Set<String>) async throws {
        try check()
        videos.withLock { videos in
            for video in sent {
                videos[video.id, default: [:]].merge(["sentBy": reason.rawValue, "watched": String(watched.contains(video.id))]) { $1 }
            }
        }
    }

    func setWatched(_ watched: [String: Bool]) async throws {
        try check()
        videos.withLock { videos in
            for (id, value) in watched { videos[id, default: [:]]["watched"] = String(value) }
        }
    }

    func videoChanges(after cursor: String?) async throws -> [PhoneVideoChange] {
        try check()
        return changes.withLock { all in all.filter { cursor == nil || $0.updatedAt > cursor! } }
    }

    func saveCookies(sealed: Data) async throws { cookies.withLock { $0 = sealed } }
    let accountFeeds = Mutex<Data?>(nil)
    let accountFeedUploads = Mutex(0)
    func saveAccountFeeds(sealed: Data) async throws {
        accountFeeds.withLock { $0 = sealed }
        accountFeedUploads.withLock { $0 += 1 }
    }

    let sharedDoc = Mutex<PhoneShared?>(nil)
    let refreshHandled = Mutex<[Date]>([])
    func shared() async throws -> PhoneShared? {
        try check()
        return sharedDoc.withLock { $0 }
    }

    func saveGroups(_ groups: [ChannelGroup]) async throws {
        try check()
        sharedDoc.withLock { doc in
            var shared = doc ?? PhoneShared()
            shared.groups = groups
            doc = shared
        }
    }

    func markRefreshHandled(requestedAt: Date) async throws {
        refreshHandled.withLock { $0.append(requestedAt) }
    }

    func push(_ data: [String: String], to token: String) async throws -> Bool {
        if let slow = slowPushState.withLock({ $0 }), data["state"] == slow {
            try await Task.sleep(for: .milliseconds(100))
        }
        pushes.withLock { $0.append((token, data)) }
        return token != "stale"
    }
}

@MainActor
struct PhoneSyncTests {
    let youtube = FakeYouTube()
    let account = FakeAccount()
    let store = Store(directory: temporaryDirectory())
    let backend = FakePhoneBackend()
    let channelId = "UCphone"
    let phone = PhoneMember(id: "uid1", name: "Galaxy S24+", fcmToken: "token1", pairedAt: nil)

    /// A model with Firebase set up and one channel (v1, v2 in New; v3…v5 in Recent).
    let notifier = FakeNotifier()

    func makeModel(paired: Bool = true) async throws -> AppModel {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.directory.appending(path: "firebase-key.json"))
        try Data("# cookies".utf8).write(to: store.directory.appending(path: "cookies.txt"))
        if paired { backend.members.withLock { $0 = [phone] } }
        youtube.channels.withLock { $0["@p"] = ChannelInfo(id: channelId, title: "P", handle: nil, avatarURL: nil) }
        youtube.publicFeeds.withLock { $0[channelId] = (1...5).map { video("v\($0)", channel: channelId, minutesAgo: Double($0)) } }
        account.state = .signedIn
        let backend = backend
        let model = AppModel(youtube: youtube, account: account, store: store, notifier: notifier,
                             cookiesFile: store.directory.appending(path: "cookies.txt"), alarmServices: .inert,
                             phoneBackend: { _ in backend })
        model.phone.debounce = .milliseconds(1)
        model.phone.pairingPollInterval = .milliseconds(10)
        model.load()
        await model.check(.launch)
        await model.phone.connect()
        try await model.addChannel(input: "@p")
        await model.phone.sync()
        return model
    }

    @Test func sharesYouTubeFeedsSealedAndReadsThemRarely() async throws {
        let feeds = AccountFeeds(
            recommended: [FeedVideo(id: "rec00000001", channelId: "UCr", channelTitle: "R", title: "Rec", duration: 60,
                                    thumbnailURL: nil, isMembersOnly: false, isLive: false)],
            subscriptions: [])
        youtube.accountFeeds.withLock { $0 = .success(feeds) }
        let model = try await makeModel()
        // Read beside the sync, uploaded at the next one.
        await model.phone.accountFeedsRead?.value
        await model.phone.sync()
        let sealed = try #require(backend.accountFeeds.withLock { $0 })
        let key = try PairingKey.loadOrCreate(at: store.directory.appending(path: "pairing-key"))
        #expect(try JSONDecoder().decode(AccountFeeds.self, from: key.open(sealed)) == feeds)

        // Not read again for a while, and not uploaded again unchanged.
        let reads = youtube.accountFeedFetches.withLock { $0 }
        let uploads = backend.accountFeedUploads.withLock { $0 }
        await model.phone.sync()
        await model.phone.sync()
        #expect(youtube.accountFeedFetches.withLock { $0 } == reads)
        #expect(backend.accountFeedUploads.withLock { $0 } == uploads)
    }

    @Test func noYouTubeFeedsWhenSignedOutOrFailing() async throws {
        youtube.accountFeeds.withLock { $0 = .failure(.network("offline")) }
        let model = try await makeModel()
        await model.phone.accountFeedsRead?.value
        await model.phone.sync()
        #expect(backend.accountFeeds.withLock { $0 } == nil)
        #expect(model.phone.connection == .connected)
    }

    @Test func connectsAndSharesChannelsAndSealedCookies() async throws {
        let model = try await makeModel()
        #expect(model.phone.connection == .connected)
        #expect(model.phone.projectId == "stow-test")
        #expect(backend.channels.withLock { $0[channelId]?.title } == "P")
        let sealed = try #require(backend.cookies.withLock { $0 })
        let key = try PairingKey.loadOrCreate(at: store.directory.appending(path: "pairing-key"))
        #expect(try key.open(sealed) == Data("# cookies".utf8))

        // Unchanged channels aren't written again; a removed one is deleted.
        backend.channels.withLock { $0 = [:] }
        await model.phone.sync()
        #expect(backend.channels.withLock { $0.isEmpty })
        backend.channels.withLock { $0 = [channelId: Channel(info: ChannelInfo(id: channelId, title: "P"))] }
        model.removeChannel(id: channelId)
        await model.phone.sync()
        #expect(backend.channels.withLock { $0.isEmpty })
    }

    @Test func newVideosStayOffThePhoneUntilSent() async throws {
        let model = try await makeModel()
        youtube.publicFeeds.withLock { $0[channelId] = [video("v0", channel: channelId, minutesAgo: 0)] + $0[channelId]! }
        await model.check(.manual)
        await model.phone.sync()
        #expect(backend.videos.withLock { $0.isEmpty })
        #expect(!model.phone.isSent(videoId: "v0"))

        model.phone.send(videoId: "v0")
        await model.phone.sync()
        #expect(backend.videos.withLock { $0["v0"]?["sentBy"] } == "manual")
        #expect(backend.pushes.withLock { $0.map(\.token) } == ["token1"])
    }

    @Test func membersVideosGoOnlyWhenTheLevelCanWatchThem() async throws {
        youtube.lockedVideos.withLock { $0 = ["m2": "Gold"] }
        youtube.membersFeeds.withLock {
            $0[channelId] = .success(MembersFeed(videos: [video("m1", channel: channelId, minutesAgo: 0, members: true),
                                                          video("m2", channel: channelId, minutesAgo: 0.5, members: true)]))
        }
        let model = try await makeModel()
        await model.check(.manual)
        await model.memberAccessChecks?.value
        #expect(model.memberAccess(videoId: "m1") == .watchable)
        #expect(model.memberAccess(videoId: "m2") == .locked(level: "Gold"))
        #expect(Set(youtube.accessChecks.withLock { $0 }) == ["m1", "m2"])
        // The Mac doesn't show it either.
        let shown = model.inbox.map(\.id) + model.recentVideos.map(\.id)
        #expect(shown.contains("m1"))
        #expect(!shown.contains("m2"))
        await model.phone.sync()
        let recent = try #require(backend.feeds.withLock { $0[channelId] }).recent.map(\.id)
        #expect(recent.contains("m1"))
        #expect(!recent.contains("m2"))
        // Sending a locked video does nothing; checks aren't repeated.
        model.phone.send(videoId: "m2")
        await model.phone.sync()
        #expect(backend.videos.withLock { $0["m2"] } == nil)
        await model.check(.manual)
        await model.memberAccessChecks?.value
        #expect(youtube.accessChecks.withLock { $0.count } == 2)
    }

    @Test func newMembersVideosAreAnnouncedOnceTheLevelCanWatchThem() async throws {
        youtube.lockedVideos.withLock { $0 = ["m4": "Gold"] }
        youtube.membersFeeds.withLock { $0[channelId] = .success(MembersFeed(videos: [])) }
        let model = try await makeModel()
        await model.check(.manual)
        await model.memberAccessChecks?.value
        youtube.membersFeeds.withLock {
            $0[channelId] = .success(MembersFeed(videos: [video("m3", channel: channelId, minutesAgo: 0, members: true),
                                                          video("m4", channel: channelId, minutesAgo: 0.2, members: true)]))
        }
        notifier.newVideoBatches = []
        await model.check(.manual)
        await model.memberAccessChecks?.value
        #expect(notifier.newVideoBatches.map { $0.map(\.id) } == [["m3"]])
        #expect(model.inbox.map(\.id).contains("m3"))
        #expect(!model.inbox.map(\.id).contains("m4"))
    }

    @Test func pastStreamsReachThePhoneWithTheirLength() async throws {
        var stream = video("s1", channel: channelId, minutesAgo: 0.5, live: .wasLive)
        stream.duration = 7200
        youtube.streamFeeds.withLock { $0[channelId] = [stream] }
        let model = try await makeModel()
        await model.phone.sync()
        let recent = try #require(backend.feeds.withLock { $0[channelId] }).recent
        #expect(recent.first { $0.id == "s1" }?.duration == 7200)
        // Not news on the Mac: a channel's streams are all seen at their first fetch.
        #expect(!model.inbox.contains { $0.id == "s1" })
    }

    @Test func groupsFromThePhoneAddTheirChannelsAndSyncBack() async throws {
        let model = try await makeModel()
        youtube.channels.withLock { $0["UCnew"] = ChannelInfo(id: "UCnew", title: "New One", handle: nil, avatarURL: nil) }
        youtube.publicFeeds.withLock { $0["UCnew"] = [] }
        backend.sharedDoc.withLock {
            $0 = PhoneShared(groups: [ChannelGroup(id: "g1", name: "Investing",
                                                   channels: [GroupChannel(id: channelId, title: "P"), GroupChannel(id: "UCnew", title: "New One")])])
        }
        await model.phone.readShared()
        #expect(model.phone.groups.map(\.name) == ["Investing"])
        for _ in 0..<200 where !model.channels.contains(where: { $0.id == "UCnew" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let added = try #require(model.channels.first { $0.id == "UCnew" })
        #expect(!added.morning)

        // Edited on the Mac: on top of the phone's latest.
        model.phone.renameGroup(id: "g1", to: "Stocks")
        for _ in 0..<200 where backend.sharedDoc.withLock({ $0?.groups.first?.name }) != "Stocks" {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Removing a channel here takes it out of its groups.
        model.removeChannel(id: "UCnew")
        for _ in 0..<200 where backend.sharedDoc.withLock({ $0?.groups.first?.channels.count }) != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backend.sharedDoc.withLock { $0?.groups.first?.channels.map(\.id) } == [channelId])
    }

    @Test func pullToRefreshOnThePhoneChecksAndAnswers() async throws {
        let model = try await makeModel()
        let requested = Date(timeIntervalSince1970: 1_900_000_000)
        backend.sharedDoc.withLock { $0 = PhoneShared(refreshRequestedAt: requested) }
        youtube.publicFeeds.withLock { $0[channelId] = [video("v0", channel: channelId, minutesAgo: 0)] + (1...5).map { video("v\($0)", channel: channelId, minutesAgo: Double($0)) } }
        await model.phone.readShared()
        #expect(model.inbox.contains { $0.id == "v0" })
        #expect(backend.refreshHandled.withLock { $0 } == [requested])
        // Answered once.
        await model.phone.readShared()
        #expect(backend.refreshHandled.withLock { $0.count } == 1)
    }

    @Test func sendToPhoneSendsAnyVideo() async throws {
        let model = try await makeModel()
        model.phone.send(videoId: "v4")
        await model.phone.sync()
        #expect(backend.videos.withLock { $0["v4"]?["sentBy"] } == "manual")
        #expect(model.phoneState.pending.isEmpty)
    }

    @Test func alarmPushesLeaveInOrder() async throws {
        let model = try await makeModel()
        backend.pushes.withLock { $0 = [] }
        backend.slowPushState.withLock { $0 = "playing" }
        model.phone.pushToPhones(["type": "alarm", "state": "playing"])
        model.phone.pushToPhones(["type": "alarm", "state": "ended"])
        for _ in 0..<200 where backend.pushes.withLock({ $0.count }) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backend.pushes.withLock { $0.map { $0.data["state"] } } == ["playing", "ended"])
    }

    @Test func nothingIsSentBeforePairing() async throws {
        let model = try await makeModel(paired: false)
        model.phone.send(videoId: "v4")
        await model.phone.sync()
        #expect(backend.videos.withLock { $0.isEmpty })
        #expect(backend.channels.withLock { $0.isEmpty })
    }

    @Test func watchedSyncsBothWays() async throws {
        let model = try await makeModel()
        model.phone.send(videoId: "v1")
        model.phone.send(videoId: "v2")
        await model.phone.sync()
        // Watched on the phone.
        backend.changes.withLock { $0 = [PhoneVideoChange(id: "v1", watched: true, download: PhoneDownload(state: .downloaded),
                                                          updatedBy: "phone", updatedAt: "2026-11-20T05:00:00.000001Z")] }
        await model.phone.sync()
        #expect(model.isWatched(videoId: "v1"))
        #expect(!model.inbox.contains { $0.id == "v1" })
        #expect(model.phone.download(videoId: "v1")?.state == .downloaded)
        #expect(model.phoneState.cursor == "2026-11-20T05:00:00.000001Z")

        // Watched here.
        model.setWatched(true, videoId: "v2")
        await model.phone.sync()
        #expect(backend.videos.withLock { $0["v2"]?["watched"] } == "true")
        // Unwatched here.
        model.setWatched(false, videoId: "v1")
        await model.phone.sync()
        #expect(backend.videos.withLock { $0["v1"]?["watched"] } == "false")
    }

    @Test func pairingAddsThePhone() async throws {
        let model = try await makeModel(paired: false)
        model.phone.startPairing()
        let invite = try #require(model.phone.pairing?.invite)
        #expect(invite.url.absoluteString.hasPrefix("stow://pair?p=stow-test&c=\(invite.code)&k="))
        #expect(invite.qrImage(size: 200) != nil)
        backend.pairingRequests.withLock { $0[invite.code] = PairingRequest(uid: "uid9", name: "Pixel", fcmToken: "t9") }
        for _ in 0..<200 where model.phone.pairing?.status == .waiting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.phone.pairing?.status == .paired(name: "Pixel"))
        #expect(model.phone.members.map(\.id) == ["uid9"])
        #expect(backend.channels.withLock { $0[channelId] } != nil)

        await model.phone.removeMember(id: "uid9")
        #expect(!model.phone.isPaired)
        #expect(backend.members.withLock { $0.isEmpty })
    }

    @Test func channelFeedsCarryRecentVideosAndWatched() async throws {
        let model = try await makeModel()
        let feed = try #require(backend.feeds.withLock { $0[channelId] })
        #expect(feed.recent.map(\.id) == ["v1", "v2", "v3", "v4", "v5"])
        #expect(feed.watched.isEmpty)
        model.setWatched(true, videoId: "v4")
        await model.phone.sync()
        #expect(backend.feeds.withLock { $0[channelId]?.watched } == ["v4"])
    }

    @Test func failuresAreReportedThenClear() async throws {
        let model = try await makeModel()
        backend.failure.withLock { $0 = .network("offline") }
        await model.phone.sync()
        #expect(model.phone.lastError != nil)
        backend.failure.withLock { $0 = nil }
        await model.phone.sync()
        #expect(model.phone.lastError == nil)
    }

    @Test func notSetUpWithoutAKey() async throws {
        let model = AppModel(youtube: youtube, account: account, store: store, notifier: FakeNotifier(),
                             cookiesFile: store.directory.appending(path: "cookies.txt"))
        await model.phone.connect()
        #expect(model.phone.connection == .notSetUp)
    }
}

struct FirebasePiecesTests {
    @Test func firestoreValuesRoundTrip() throws {
        let value = FirestoreValue.map(["a": .string("x"), "b": .int(3), "c": .bool(true), "d": .null,
                                        "e": .array([.double(1.5), .timestamp("2026-11-20T05:00:00.123456Z")])])
        let data = try JSONSerialization.data(withJSONObject: value.json)
        #expect(FirestoreValue(json: try JSONSerialization.jsonObject(with: data)) == value)
        #expect(FirestoreValue.timestamp("2026-11-20T05:00:00.123456Z").date != nil)
    }

    @Test func serviceAccountSignsAVerifiableJWT() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(privateKey, nil) as Data?)
        let pem = "-----BEGIN PRIVATE KEY-----\n\(Self.pkcs8(pkcs1).base64EncodedString(options: .lineLength64Characters))\n-----END PRIVATE KEY-----\n"
        let json: [String: Any] = ["type": "service_account", "project_id": "stow-test", "private_key_id": "k1",
                                   "private_key": pem, "client_email": "sa@stow-test.iam.gserviceaccount.com",
                                   "token_uri": "https://oauth2.googleapis.com/token"]
        let account = try ServiceAccount(json: JSONSerialization.data(withJSONObject: json))
        #expect(account.projectId == "stow-test")

        let jwt = try account.assertion()
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let signature = try #require(Data(base64URL: parts[2]))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        #expect(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                      Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil))
        let payload = try #require(Data(base64URL: parts[1]))
        let claims = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(claims["iss"] as? String == "sa@stow-test.iam.gserviceaccount.com")
        #expect((claims["scope"] as? String)?.contains("datastore") == true)

        #expect(throws: StowError.self) { try ServiceAccount(json: Data(#"{"hello": 1}"#.utf8)) }
    }

    @Test func pairingKeySealsAndPersists() throws {
        let file = temporaryDirectory().appending(path: "pairing-key")
        let key = try PairingKey.loadOrCreate(at: file)
        let sealed = try key.seal(Data("secret".utf8))
        #expect(try PairingKey.loadOrCreate(at: file).open(sealed) == Data("secret".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    /// PrivateKeyInfo { 0, rsaEncryption, OCTET STRING pkcs1 }.
    static func pkcs8(_ pkcs1: Data) -> Data {
        func element(_ tag: UInt8, _ content: Data) -> Data {
            var length = Data()
            if content.count < 0x80 {
                length.append(UInt8(content.count))
            } else {
                var bytes = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Data($0) }
                while bytes.first == 0 { bytes.removeFirst() }
                length.append(0x80 | UInt8(bytes.count))
                length.append(bytes)
            }
            return Data([tag]) + length + content
        }
        let algorithm = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        return element(0x30, Data([0x02, 0x01, 0x00]) + algorithm + element(0x04, pkcs1))
    }
}

private extension Data {
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
