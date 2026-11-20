#if DEBUG
import Foundation

/// `Stow --phone-check <google-services.json output>` (Debug builds only): runs phone sync
/// against the real Firebase project with a pretend phone, which uses the REST APIs exactly as
/// the Android app will (anonymous sign-in, security rules enforced). Works on copies of
/// settings/state in a scratch folder; cleans up the documents and user it creates. Also saves
/// the Android app's google-services.json.
@MainActor
enum PhoneCheck {
    static let argument = "--phone-check"

    private static var failures = 0

    static func run() async -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: argument), args.indices.contains(index + 1) else {
            print("usage: Stow --phone-check <where to save google-services.json>")
            return false
        }
        let configOutput = URL(filePath: args[index + 1])
        let scratch = FileManager.default.temporaryDirectory.appending(path: "stow-phone-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try await check(scratch: scratch, configOutput: configOutput)
        } catch {
            fail("stopped: \(error.logDescription)")
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }

    private static func check(scratch: URL, configOutput: URL) async throws {
        let http = FirebaseHTTP()
        let account = try ServiceAccount(json: Data(contentsOf: AppPaths.firebaseKeyFile))
        let projectId = account.projectId

        // The Android app's config, which also holds the Web API key the phone signs in with.
        let management = GoogleAuth(account: account, http: http, scopes: ["https://www.googleapis.com/auth/firebase.readonly"])
        let config = try await androidConfig(projectId: projectId, auth: management, http: http)
        try FileManager.default.createDirectory(at: configOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.write(to: configOutput, options: .atomic)
        let apiKey = try apiKey(fromGoogleServices: config)
        pass("google-services.json saved (\(config.count) bytes), API key found")

        // The Mac: a model on copies of the real files, with the real key.
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for file in [AppPaths.settingsFile, AppPaths.stateFile, AppPaths.cookiesFile, AppPaths.firebaseKeyFile]
        where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.copyItem(at: file, to: scratch.appending(path: file.lastPathComponent))
        }
        let model = AppModel(youtube: YouTubeClient(), account: CheckAccount(), store: Store(directory: scratch),
                             notifier: CheckNotifier(), cookiesFile: scratch.appending(path: "cookies.txt"))
        model.load()
        // Starts from no phones, whatever the copied state says.
        model.updatePhoneState { $0 = .empty }
        await model.signIn()
        await model.phone.connect()
        expect(model.phone.connection == .connected, "Mac connects with the key (\(model.phone.connection))")

        // The phone signs in anonymously.
        let phone = try await PretendPhone.signUp(apiKey: apiKey, projectId: projectId, http: http)
        pass("phone signed in anonymously")
        let serviceAuth = GoogleAuth(account: account, http: http)
        let admin = FirestoreREST(projectId: projectId, token: { try await serviceAuth.accessToken() }, http: http)
        do {
            try await expectDenied("unpaired phone can't read channels") { _ = try await phone.firestore.list("channels") }
            try await expectDenied("unpaired phone can't read its member document") { _ = try await phone.firestore.get("members/\(phone.uid)") }

            // Pairing.
            model.phone.pairingPollInterval = .milliseconds(500)
            model.phone.startPairing()
            guard let invite = model.phone.pairing?.invite else { throw StowError.parse("no pairing invite") }
            try await expectDenied("short pairing codes are refused") {
                try await phone.firestore.commit([.merge(path: "pairing/short", fields: ["uid": .string(phone.uid)], stampsUpdatedAt: false)])
            }
            try await expectDenied("a pairing request for another uid is refused") {
                try await phone.firestore.commit([.merge(path: "pairing/\(invite.code)", fields: ["uid": .string("someone-else")], stampsUpdatedAt: false)])
            }
            try await phone.firestore.commit([.merge(path: "pairing/\(invite.code)", fields: [
                "uid": .string(phone.uid), "name": .string("Phone check"), "fcmToken": .string("stow-check-not-a-real-token"),
            ], stampsUpdatedAt: false)])
            pass("phone filed its pairing request")
            for _ in 0..<60 where model.phone.pairing?.status == .waiting {
                try await Task.sleep(for: .milliseconds(250))
            }
            expect(model.phone.pairing?.status == .paired(name: "Phone check"), "Mac paired the phone (\(String(describing: model.phone.pairing?.status)))")
            await model.phone.sync()

            // What a paired phone can read.
            expect(try await phone.firestore.get("members/\(phone.uid)") != nil, "paired phone reads its member document")
            let channels = try await phone.firestore.list("channels")
            expect(channels.count == model.channels.count && !channels.isEmpty, "phone reads the channels (\(channels.count))")
            if let sealed = try await phone.firestore.get("secrets/cookies")?.fields["sealed"]?.string.flatMap({ Data(base64Encoded: $0) }) {
                let key = try PairingKey.loadOrCreate(at: scratch.appending(path: AppPaths.pairingKeyFile.lastPathComponent))
                let cookies = try key.open(sealed)
                expect(cookies == (try Data(contentsOf: scratch.appending(path: "cookies.txt"))), "phone decrypts the YouTube cookies")
                expect(key.base64URL == invite.keyBase64URL, "the QR code carries the cookie key")
            } else {
                fail("phone found no sealed cookies")
            }
            try await expectDenied("phone can't change channels") {
                try await phone.firestore.commit([.merge(path: "channels/\(channels[0].id)", fields: ["title": .string("x")])])
            }
            try await expectDenied("phone can't read pairing requests") { _ = try await phone.firestore.get("pairing/\(invite.code)") }

            // Send a video; the push goes to a made-up token, which FCM must reject as invalid.
            guard let video = model.recentVideos.first(where: { !model.isWatched(videoId: $0.id) }) else {
                throw StowError.parse("no unwatched recent video to send")
            }
            model.phone.send(videoId: video.id)
            await model.phone.sync()
            let sent = try await phone.firestore.get("videos/\(video.id)")
            expect(sent?.fields["title"]?.string == video.title && sent?.fields["sentBy"]?.string == "manual",
                   "phone reads the sent video “\(video.title)”")
            let pushLog = model.log.first { $0.message.contains("push token is out of date") || $0.message.contains("Couldn't wake") }
            expect(pushLog?.message.contains("out of date") == true,
                   "FCM answered (the made-up token is reported out of date): \(pushLog?.message ?? "no push logged")")

            // The phone reports progress and watches it.
            try await phone.firestore.commit([.merge(path: "videos/\(video.id)", fields: [
                "watched": .bool(true), "watchedBy": .string("phone"),
                "phone": .map(["state": .string("downloaded")]), "updatedBy": .string("phone"),
            ])])
            pass("phone marked the video downloaded and watched")
            try await expectDenied("phone can't change a video's title") {
                try await phone.firestore.commit([.merge(path: "videos/\(video.id)", fields: ["title": .string("x")])])
            }
            await model.phone.sync()
            expect(model.isWatched(videoId: video.id), "Mac shows it watched")
            expect(model.phone.download(videoId: video.id)?.state == .downloaded, "Mac shows it on the phone")

            // Unwatched on the Mac reaches the phone.
            model.setWatched(false, videoId: video.id)
            await model.phone.sync()
            expect(try await phone.firestore.get("videos/\(video.id)")?.fields["watched"]?.bool == false, "Mac's unwatch reaches the phone")

            // Unpairing locks the phone out.
            await model.phone.removeMember(id: phone.uid)
            try await expectDenied("unpaired phone is locked out again") { _ = try await phone.firestore.list("channels") }
        } catch {
            fail("stopped: \(error.logDescription)")
        }

        // Clean up what the check wrote; the real app writes its own when the real phone pairs.
        let videos = try await admin.list("videos").map { FirestoreWrite.delete(path: "videos/\($0.id)") }
        let channels = try await admin.list("channels").map { FirestoreWrite.delete(path: "channels/\($0.id)") }
        try await admin.commit(videos + channels + [.delete(path: "secrets/cookies"), .delete(path: "members/\(phone.uid)")])
        try await phone.delete()
        let left = try await admin.list("videos").count + admin.list("channels").count + admin.list("members").count
        expect(left == 0, "cleaned up the test documents and the test user")
    }

    private static func androidConfig(projectId: String, auth: GoogleAuth, http: FirebaseHTTP) async throws -> Data {
        func get(_ path: String) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "https://firebase.googleapis.com/v1beta1/\(path)")!)
            request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, status) = try await http.send(request)
            guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StowError.network("Firebase management API (HTTP \(status)): \(FirebaseHTTP.message(from: data))")
            }
            return object
        }
        let apps = try await get("projects/\(projectId)/androidApps")["apps"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { $0["packageName"] as? String == "dev.stow.android" }),
              let appId = app["appId"] as? String else {
            throw StowError.parse("No Android app dev.stow.android in the project")
        }
        let config = try await get("projects/\(projectId)/androidApps/\(appId)/config")
        guard let contents = config["configFileContents"] as? String, let data = Data(base64Encoded: contents) else {
            throw StowError.parse("No config file for the Android app")
        }
        return data
    }

    private static func apiKey(fromGoogleServices data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let clients = object?["client"] as? [[String: Any]] ?? []
        let keys = clients.flatMap { $0["api_key"] as? [[String: Any]] ?? [] }
        guard let key = keys.first?["current_key"] as? String else { throw StowError.parse("No API key in google-services.json") }
        return key
    }

    private static func expectDenied(_ name: String, _ action: () async throws -> Void) async throws {
        do {
            try await action()
            fail("\(name): it was allowed")
        } catch StowError.network(let message) where message.contains("HTTP 403") {
            pass(name)
        }
    }

    private static func expect(_ condition: Bool, _ name: String) {
        condition ? pass(name) : fail(name)
    }

    private static func pass(_ name: String) { print("PASS  \(name)") }

    private static func fail(_ name: String) {
        failures += 1
        print("FAIL  \(name)")
    }
}

/// The Android app's side, over REST with a Firebase Auth ID token (security rules apply).
private struct PretendPhone {
    let uid: String
    let idToken: String
    let apiKey: String
    let firestore: FirestoreREST
    let http: FirebaseHTTP

    static func signUp(apiKey: String, projectId: String, http: FirebaseHTTP) async throws -> PretendPhone {
        let object = try await identity("accounts:signUp", apiKey: apiKey, body: ["returnSecureToken": true], http: http)
        guard let idToken = object["idToken"] as? String, let uid = object["localId"] as? String else {
            throw StowError.parse("Anonymous sign-in returned no token")
        }
        return PretendPhone(uid: uid, idToken: idToken, apiKey: apiKey,
                            firestore: FirestoreREST(projectId: projectId, token: { idToken }, http: http), http: http)
    }

    func delete() async throws {
        _ = try await Self.identity("accounts:delete", apiKey: apiKey, body: ["idToken": idToken], http: http)
    }

    private static func identity(_ method: String, apiKey: String, body: [String: Any], http: FirebaseHTTP) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/\(method)?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await http.send(request)
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StowError.network("Firebase Auth \(method) (HTTP \(status)): \(FirebaseHTTP.message(from: data))")
        }
        return object
    }
}

@MainActor
private final class CheckAccount: AccountService {
    func refresh() async -> SignInState { .signedIn }
    func signIn() async -> Bool { true }
    func signOut() async {}
    func fetchSubscriptions() async throws -> [ChannelInfo] { [] }
}

@MainActor
private final class CheckNotifier: UserNotifying {
    func requestAuthorization() async -> Bool { true }
    func notifyNewVideos(_ videos: [Video]) {}
    func notifyProblem(title: String, body: String) {}
}
#endif
