import Foundation

/// `PhoneBackend` on the user's Firebase project: Firestore and FCM over REST, signed in with
/// the project's service-account key.
struct FirebaseBackend: PhoneBackend {
    let projectId: String
    private let firestore: FirestoreREST
    private let fcm: FCMREST

    init(account: ServiceAccount) {
        let http = FirebaseHTTP()
        let auth = GoogleAuth(account: account, http: http)
        let token: @Sendable () async throws -> String = { try await auth.accessToken() }
        projectId = account.projectId
        firestore = FirestoreREST(projectId: account.projectId, token: token, http: http)
        fcm = FCMREST(projectId: account.projectId, token: token, http: http)
    }

    /// Reads the key file. Throws `.parse` when it isn't a service-account key.
    init(keyFile: URL) throws {
        try self.init(account: ServiceAccount(json: Data(contentsOf: keyFile)))
    }

    func members() async throws -> [PhoneMember] {
        try await firestore.list("members").map { document in
            PhoneMember(id: document.id, name: document.fields["name"]?.string ?? "Phone",
                        fcmToken: document.fields["fcmToken"]?.string, pairedAt: document.fields["pairedAt"]?.date)
        }
    }

    func takePairingRequest(code: String) async throws -> PairingRequest? {
        guard let document = try await firestore.get("pairing/\(code)") else { return nil }
        try await firestore.commit([.delete(path: "pairing/\(code)")])
        guard let uid = document.fields["uid"]?.string, !uid.isEmpty else { return nil }
        return PairingRequest(uid: uid, name: document.fields["name"]?.string ?? "Phone",
                              fcmToken: document.fields["fcmToken"]?.string)
    }

    func addMember(_ member: PhoneMember) async throws {
        try await firestore.commit([.merge(path: "members/\(member.id)", fields: [
            "name": .string(member.name),
            "fcmToken": .optional(member.fcmToken),
            "pairedAt": .date(member.pairedAt ?? .now),
        ])])
    }

    func removeMember(id: String) async throws {
        try await firestore.commit([.delete(path: "members/\(id)")])
    }

    func saveChannels(_ feeds: [PhoneChannelFeed], removing: [String]) async throws {
        let writes = feeds.enumerated().map { order, feed in
            let channel = feed.channel
            return FirestoreWrite.merge(path: "channels/\(channel.id)", fields: [
                "title": .string(channel.title),
                "handle": .optional(channel.handle),
                "avatarURL": .optional(channel.avatarURL?.absoluteString),
                "phone": .bool(channel.phone),
                "morning": .bool(channel.morning),
                "order": .int(order),
                "recent": .array(feed.recent.map { video in
                    .map([
                        "id": .string(video.id),
                        "title": .string(video.title),
                        "publishedAt": video.publishedAt.map(FirestoreValue.date) ?? .null,
                        "thumbnailURL": .optional(video.thumbnailURL?.absoluteString),
                        "isMembersOnly": .bool(video.isMembersOnly),
                        "liveStatus": .string(video.liveStatus.rawValue),
                        "watched": .bool(feed.watched.contains(video.id)),
                    ])
                }),
                "updatedBy": .string("mac"),
            ])
        } + removing.map { FirestoreWrite.delete(path: "channels/\($0)") }
        try await firestore.commit(writes)
    }

    func channelChanges(after cursor: String?) async throws -> [PhoneChannelChange] {
        try await firestore.changed("channels", after: cursor).compactMap { document in
            guard let updatedAt = document.fields["updatedAt"]?.timestamp else { return nil }
            return PhoneChannelChange(id: document.id, phone: document.fields["phone"]?.bool,
                                      updatedBy: document.fields["updatedBy"]?.string, updatedAt: updatedAt)
        }
    }

    func sendVideos(_ videos: [Video], reason: PhoneSendReason, watched: Set<String>) async throws {
        let now = Date.now
        try await firestore.commit(videos.map { video in
            .merge(path: "videos/\(video.id)", fields: [
                "channelId": .string(video.channelId),
                "channelTitle": .string(video.channelTitle),
                "title": .string(video.title),
                "publishedAt": video.publishedAt.map(FirestoreValue.date) ?? .null,
                "thumbnailURL": .optional(video.thumbnailURL?.absoluteString),
                "isMembersOnly": .bool(video.isMembersOnly),
                "liveStatus": .string(video.liveStatus.rawValue),
                "sentAt": .date(now),
                "sentBy": .string(reason.rawValue),
                "watched": .bool(watched.contains(video.id)),
                "updatedBy": .string("mac"),
            ])
        })
    }

    func setWatched(_ watched: [String: Bool]) async throws {
        let now = Date.now
        try await firestore.commit(watched.sorted { $0.key < $1.key }.map { id, isWatched in
            .merge(path: "videos/\(id)", fields: [
                "watched": .bool(isWatched),
                "watchedAt": isWatched ? .date(now) : .null,
                "watchedBy": isWatched ? .string("mac") : .null,
                "updatedBy": .string("mac"),
            ])
        })
    }

    func videoChanges(after cursor: String?) async throws -> [PhoneVideoChange] {
        try await firestore.changed("videos", after: cursor).compactMap { document in
            guard let updatedAt = document.fields["updatedAt"]?.timestamp else { return nil }
            let phone = document.fields["phone"]?.map
            let download = phone?["state"]?.string.flatMap(PhoneDownloadState.init(rawValue:)).map {
                PhoneDownload(state: $0, error: phone?["error"]?.string)
            }
            return PhoneVideoChange(id: document.id, watched: document.fields["watched"]?.bool, download: download,
                                    updatedBy: document.fields["updatedBy"]?.string, updatedAt: updatedAt)
        }
    }

    func saveCookies(sealed: Data) async throws {
        try await firestore.commit([.merge(path: "secrets/cookies", fields: [
            "sealed": .string(sealed.base64EncodedString()),
            "algorithm": .string("ChaChaPoly"),
        ])])
    }

    func saveAccountFeeds(sealed: Data) async throws {
        try await firestore.commit([.merge(path: "secrets/feeds", fields: [
            "sealed": .string(sealed.base64EncodedString()),
            "algorithm": .string("ChaChaPoly"),
            "updatedAt": .string(ISO8601DateFormatter().string(from: .now)),
        ])])
    }

    func push(_ data: [String: String], to token: String) async throws -> Bool {
        try await fcm.send(data: data, to: token) == .sent
    }

    #if DEBUG
    var firestoreForTests: FirestoreREST { firestore }
    #endif
}
