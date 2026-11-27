import Foundation
import Testing
@testable import StowKit

/// Firebase over REST against a stub URLProtocol: nothing leaves the process.
@Suite struct RESTTests {
    private let signUpAnswer = #"{"kind":"identitytoolkit#SignupNewUserResponse","idToken":"id-token-1","refreshToken":"refresh-1","expiresIn":"3600","localId":"phone-uid"}"#

    @Test func signsUpAnonymouslyOnceAndKeepsTheTokens() async throws {
        let server = StubServer { request in
            #expect(request.method == "POST")
            #expect(request.url.host == "identitytoolkit.googleapis.com")
            #expect(request.path == "/v1/accounts:signUp")
            #expect(request.query["key"] == ["test-api-key"])
            #expect(request.json["returnSecureToken"] as? Bool == true)
            return (200, #"{"kind":"identitytoolkit#SignupNewUserResponse","idToken":"id-token-1","refreshToken":"refresh-1","expiresIn":"3600","localId":"phone-uid"}"#)
        }
        let store = InMemoryTokenStore()
        let auth = FirebaseAuth(config: testConfig, session: server.session, store: store)
        #expect(try await auth.signIn() == "phone-uid")
        #expect(try await auth.signIn() == "phone-uid")
        #expect(server.requests.count == 1)
        #expect(store.load()?.refreshToken == "refresh-1")
        #expect(try await auth.idToken() == "id-token-1")
        // A new launch reads them back.
        let again = FirebaseAuth(config: testConfig, session: server.session, store: store)
        #expect(await again.uid == "phone-uid")
    }

    @Test func renewsAnExpiringToken() async throws {
        let server = StubServer { request in
            #expect(request.url.host == "securetoken.googleapis.com")
            #expect(request.path == "/v1/token")
            #expect(request.query["key"] == ["test-api-key"])
            #expect(request.bodyText == "grant_type=refresh_token&refresh_token=old%2Brefresh")
            return (200, #"{"access_token":"id-token-2","expires_in":"3600","token_type":"Bearer","refresh_token":"refresh-2","id_token":"id-token-2","user_id":"phone-uid","project_id":"1"}"#)
        }
        let store = InMemoryTokenStore(AuthTokens(uid: "phone-uid", idToken: "id-token-1", refreshToken: "old+refresh", expiresAt: .now.addingTimeInterval(60)))
        let auth = FirebaseAuth(config: testConfig, session: server.session, store: store)
        async let first = auth.idToken()
        async let second = auth.idToken()
        #expect(try await [first, second] == ["id-token-2", "id-token-2"])
        // Both callers share one renewal.
        #expect(server.requests.count == 1)
        #expect(store.load()?.refreshToken == "refresh-2")
    }

    @Test func aDeletedUserSignsOut() async throws {
        let server = StubServer { _ in (400, #"{"error":{"code":400,"message":"USER_NOT_FOUND","status":"INVALID_ARGUMENT"}}"#) }
        let store = InMemoryTokenStore(AuthTokens(uid: "phone-uid", idToken: "old", refreshToken: "r", expiresAt: .distantPast))
        let auth = FirebaseAuth(config: testConfig, session: server.session, store: store)
        await #expect(throws: StowError.notPaired) { try await auth.idToken() }
        #expect(store.load() == nil)
    }

    @Test func getsADocumentWithTheIDToken() async throws {
        let server = StubServer { request in
            #expect(request.method == "GET")
            #expect(request.headers["Authorization"] == "Bearer id-token-1")
            switch request.path {
            case "\(documentsPrefix)/shared/phone": return (200, try! fixture("shared-phone.json"))
            default: return (404, #"{"error":{"code":404,"message":"Document not found","status":"NOT_FOUND"}}"#)
            }
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        let shared = try await remote.shared()
        #expect(shared.groups.count == 2)
        #expect(try await remote.firestore.get("videos/missing") == nil)
        // No shared/phone yet: no groups.
        server.setHandler { _ in (404, #"{"error":{"code":404,"status":"NOT_FOUND"}}"#) }
        #expect(try await remote.shared() == SharedState())
    }

    @Test func listsFollowPages() async throws {
        let server = StubServer { request in
            #expect(request.path == "\(documentsPrefix)/videos")
            #expect(request.query["pageSize"] == ["300"])
            if request.query["pageToken"] == ["page 2+"] {
                return (200, #"{"documents":[{"name":"projects/stow-test/databases/(default)/documents/videos/bbbbbbbbbbb","fields":{"title":{"stringValue":"B"}}}]}"#)
            }
            return (200, #"{"documents":[{"name":"projects/stow-test/databases/(default)/documents/videos/aaaaaaaaaaa","fields":{"title":{"stringValue":"A"}}}],"nextPageToken":"page 2+"}"#)
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        #expect(try await remote.videos().map(\.video.id) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        // The token is percent-encoded, '+' included.
        #expect(server.requests.last?.url.absoluteString.contains("pageToken=page%202%2B") == true)
    }

    @Test func patchSendsTheMaskAndFields() async throws {
        let server = StubServer { request in
            #expect(request.method == "PATCH")
            #expect(request.path == "\(documentsPrefix)/members/phone-uid")
            #expect(request.query["updateMask.fieldPaths"] == ["lastSeenAt", "name"])
            let fields = request.json["fields"] as? [String: Any]
            #expect((fields?["name"] as? [String: Any])?["stringValue"] as? String == "Kim's iPhone")
            return (200, #"{"name":"projects/stow-test/databases/(default)/documents/members/phone-uid","fields":{"name":{"stringValue":"Kim's iPhone"}}}"#)
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        let saved = try await remote.firestore.patch("members/phone-uid", ["name": "Kim's iPhone", "lastSeenAt": .date(.now)],
                                                     mask: ["name", "lastSeenAt"].sorted())
        #expect(saved?["name"]?.string == "Kim's iPhone")
    }

    @Test func setWatchedCommitsOnlyAllowedFieldsWithServerTimes() async throws {
        let server = StubServer { request in
            #expect(request.method == "POST")
            #expect(request.path == "\(documentsPrefix):commit")
            return (200, #"{"writeResults":[{"updateTime":"2026-11-27T09:00:00.1Z","transformResults":[{"timestampValue":"2026-11-27T09:00:00.1Z"},{"timestampValue":"2026-11-27T09:00:00.1Z"}]}],"commitTime":"2026-11-27T09:00:00.1Z"}"#)
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        try await remote.setWatched("dQw4w9WgXcQ", watched: true)
        let write = try #require((server.requests[0].json["writes"] as? [[String: Any]])?.first)
        let update = try #require(write["update"] as? [String: Any])
        #expect(update["name"] as? String == "projects/stow-test/databases/(default)/documents/videos/dQw4w9WgXcQ")
        let fields = try #require(update["fields"] as? [String: Any])
        #expect(Set(fields.keys) == ["watched", "watchedBy", "updatedBy"])
        #expect((write["updateMask"] as? [String: Any])?["fieldPaths"] as? [String] == ["updatedBy", "watched", "watchedBy"])
        let transforms = try #require(write["updateTransforms"] as? [[String: Any]])
        #expect(transforms.map { $0["fieldPath"] as? String } == ["updatedAt", "watchedAt"])
        #expect(transforms.allSatisfy { $0["setToServerValue"] as? String == "REQUEST_TIME" })
        // Like the SDK's update: only an existing video.
        #expect((write["currentDocument"] as? [String: Any])?["exists"] as? Bool == true)
        // Never the Android phone's download state.
        #expect(fields["phone"] == nil)

        try await remote.setWatched("dQw4w9WgXcQ", watched: false)
        let unwatch = try #require((server.requests[1].json["writes"] as? [[String: Any]])?.first)
        let unwatchFields = try #require((unwatch["update"] as? [String: Any])?["fields"] as? [String: Any])
        #expect(Set(unwatchFields.keys) == ["watched", "watchedAt", "watchedBy", "updatedBy"])
        #expect((unwatchFields["watchedAt"] as? [String: Any])?["nullValue"] != nil)
    }

    @Test func requestDownloadCreatesWhatTheRulesAllow() async throws {
        let server = StubServer { _ in (200, #"{"writeResults":[{}],"commitTime":"2026-11-27T09:00:00Z"}"#) }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        try await remote.requestDownload(Video(id: "n61ULEU7CO0", channelId: "UCSJ", channelTitle: "Lofi Girl", title: "Best of lofi",
                                               publishedAt: nil, thumbnailURL: nil, isMembersOnly: false, durationSeconds: 22258))
        let write = try #require((server.requests[0].json["writes"] as? [[String: Any]])?.first)
        let fields = try #require((write["update"] as? [String: Any])?["fields"] as? [String: Any])
        let transformed = (write["updateTransforms"] as? [[String: Any]] ?? []).compactMap { $0["fieldPath"] as? String }
        let allowed: Set<String> = ["channelId", "channelTitle", "title", "publishedAt", "thumbnailURL", "isMembersOnly",
                                    "liveStatus", "sentAt", "sentBy", "watched", "updatedAt", "updatedBy"]
        #expect(Set(fields.keys).union(transformed).isSubset(of: allowed))
        #expect(Set(transformed) == ["sentAt", "updatedAt"])
        #expect((fields["sentBy"] as? [String: Any])?["stringValue"] as? String == "phone")
        #expect((fields["updatedBy"] as? [String: Any])?["stringValue"] as? String == "phone")
        // A set, not a merge: no mask.
        #expect(write["updateMask"] == nil)
    }

    @Test func requestRefreshReturnsTheServerTime() async throws {
        let server = StubServer { _ in
            (200, #"{"writeResults":[{"updateTime":"2026-11-27T09:00:00.123456Z","transformResults":[{"timestampValue":"2026-11-27T09:00:00.123456Z"}]}],"commitTime":"2026-11-27T09:00:00.123456Z"}"#)
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        let time = try await remote.requestRefresh()
        #expect(abs(time.timeIntervalSince1970 - 1_795_770_000.123456) < 0.000_01)
        let write = try #require((server.requests[0].json["writes"] as? [[String: Any]])?.first)
        #expect(((write["update"] as? [String: Any])?["fields"] as? [String: Any])?.isEmpty == true)
        #expect((write["updateMask"] as? [String: Any])?["fieldPaths"] as? [String] == [])
    }

    @Test func permissionDeniedMeansNotPaired() async throws {
        let server = StubServer { _ in (403, try! fixture("permission-denied.json")) }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        await #expect(throws: StowError.notPaired) { try await remote.videos() }
        await #expect(throws: StowError.notPaired) { try await remote.setWatched("x", watched: true) }
        #expect(try await remote.isMember() == false)
    }

    @Test func otherErrorsSayWhatFailed() async throws {
        let server = StubServer { _ in (503, #"{"error":{"code":503,"message":"The service is currently unavailable.","status":"UNAVAILABLE"}}"#) }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        do {
            _ = try await remote.channels()
            Issue.record("Expected an error")
        } catch let error as StowError {
            #expect(error.message.contains("HTTP 503"))
            #expect(error.message.contains("currently unavailable"))
        }
    }

    @Test func anExpiredTokenIsRenewedOnce() async throws {
        let server = StubServer { request in
            if request.url.host == "securetoken.googleapis.com" {
                return (200, #"{"id_token":"id-token-2","refresh_token":"refresh-2","expires_in":"3600","user_id":"phone-uid"}"#)
            }
            if request.headers["Authorization"] == "Bearer id-token-2" {
                return (200, #"{"name":"projects/stow-test/databases/(default)/documents/members/phone-uid","fields":{}}"#)
            }
            return (401, #"{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}"#)
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        #expect(try await remote.isMember())
        #expect(server.requests.map { $0.url.host ?? "" } == ["firestore.googleapis.com", "securetoken.googleapis.com", "firestore.googleapis.com"])
    }

    @Test func pairingFilesTheRequestAndWaitsForTheMac() async throws {
        let code = String(repeating: "c", count: 43)
        let state = Counter()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("POST", "/v1/accounts:signUp"):
                return (200, #"{"idToken":"id-token-1","refreshToken":"refresh-1","expiresIn":"3600","localId":"phone-uid"}"#)
            case ("POST", "\(documentsPrefix):commit"):
                let write = (request.json["writes"] as? [[String: Any]])?.first
                let update = write?["update"] as? [String: Any]
                #expect(update?["name"] as? String == "projects/stow-test/databases/(default)/documents/pairing/\(code)")
                let fields = update?["fields"] as? [String: Any]
                #expect((fields?["uid"] as? [String: Any])?["stringValue"] as? String == "phone-uid")
                #expect((fields?["name"] as? [String: Any])?["stringValue"] as? String == "Test iPhone")
                #expect((fields?["fcmToken"] as? [String: Any])?["nullValue"] != nil)
                return (200, #"{"writeResults":[{}]}"#)
            case ("GET", "\(documentsPrefix)/members/phone-uid"):
                // The Mac adds the member on the third look.
                if state.next() < 3 { return (403, try! fixture("permission-denied.json")) }
                return (200, #"{"name":"projects/stow-test/databases/(default)/documents/members/phone-uid","fields":{"name":{"stringValue":"Test iPhone"}}}"#)
            default:
                Issue.record("Unexpected \(request.method) \(request.path)")
                return (500, "{}")
            }
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore())
        try await remote.pair(Invite(projectId: "stow-test", code: code, key: "k"), deviceName: "Test iPhone", pollEvery: .milliseconds(5))
        #expect(state.value == 3)

        await #expect(throws: StowError.self) {
            try await remote.pair(Invite(projectId: "someone-else", code: code, key: "k"), deviceName: "x")
        }
    }

    @Test func groupEditsRunInATransaction() async throws {
        let server = StubServer { request in
            switch request.path {
            case "\(documentsPrefix):beginTransaction":
                #expect(request.json["options"] != nil)
                return (200, #"{"transaction":"dHgx+/="}"#)
            case "\(documentsPrefix)/shared/phone":
                #expect(request.query["transaction"] == ["dHgx+/="])
                #expect(request.url.absoluteString.contains("transaction=dHgx%2B%2F%3D"))
                return (200, try! fixture("shared-phone.json"))
            case "\(documentsPrefix):commit":
                #expect(request.json["transaction"] as? String == "dHgx+/=")
                return (200, #"{"writeResults":[{}]}"#)
            default:
                return (500, "{}")
            }
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        try await remote.editGroups { groups in groups.filter { $0.id != "g2" } }
        let commit = try #require(server.requests.last)
        let write = try #require((commit.json["writes"] as? [[String: Any]])?.first)
        #expect((write["updateMask"] as? [String: Any])?["fieldPaths"] as? [String] == ["groups", "groupsUpdatedBy"])
        let fields = try #require((write["update"] as? [String: Any])?["fields"] as? [String: Any])
        let groups = FirestoreValue(json: fields["groups"]!).array
        #expect(groups?.count == 1)
        #expect(groups?.first?.map?["id"]?.string == "g1")
        #expect(groups?.first?.map?["channels"]?.array?.count == 2)
    }

    @Test func aTransactionThatLostIsRunAgain() async throws {
        let commits = Counter()
        let server = StubServer { request in
            switch request.path {
            case "\(documentsPrefix):beginTransaction": return (200, #"{"transaction":"t"}"#)
            case "\(documentsPrefix)/shared/phone": return (404, #"{"error":{"code":404,"status":"NOT_FOUND"}}"#)
            case "\(documentsPrefix):commit":
                if commits.next() == 1 { return (409, #"{"error":{"code":409,"message":"Transaction lock timeout.","status":"ABORTED"}}"#) }
                return (200, #"{"writeResults":[{}]}"#)
            default: return (500, "{}")
            }
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        try await remote.editGroups { $0 + [ChannelGroup(id: "new", name: "New", channels: [])] }
        #expect(commits.value == 2)
    }

    @Test func cookiesAreOpenedWithThePairingKey() async throws {
        let key = Data((0..<32).map { UInt8($0) })
        let sealed = try SealHelper.seal(Data("# Netscape HTTP Cookie File\n".utf8), key: key)
        let server = StubServer { request in
            #expect(request.path == "\(documentsPrefix)/secrets/cookies")
            return (200, #"{"name":"projects/stow-test/databases/(default)/documents/secrets/cookies","fields":{"sealed":{"stringValue":"\#(sealed.base64EncodedString())"},"algorithm":{"stringValue":"ChaChaPoly"}}}"#)
        }
        let remote = Remote(config: testConfig, session: server.session, tokenStore: InMemoryTokenStore(validTokens()))
        let cookies = try await remote.cookies(key: key)
        #expect(cookies.map { String(decoding: $0, as: UTF8.self) } == "# Netscape HTTP Cookie File\n")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    @discardableResult func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
