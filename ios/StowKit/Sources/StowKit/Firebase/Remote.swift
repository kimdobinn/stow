import Foundation

/// shared/phone: the channel groups and the Mac's answer to the last pull-to-refresh.
public struct SharedState: Hashable, Sendable {
    public var groups: [ChannelGroup]
    public var refreshRequestedAt: Date?
    public var refreshHandledAt: Date?

    public init(groups: [ChannelGroup] = [], refreshRequestedAt: Date? = nil, refreshHandledAt: Date? = nil) {
        self.groups = groups
        self.refreshRequestedAt = refreshRequestedAt
        self.refreshHandledAt = refreshHandledAt
    }
}

/// The phone's side of the Firestore layout the Mac writes (see firebase/firestore.rules):
/// members/{uid}, pairing/{code}, channels/{id}, videos/{id}, shared/phone, secrets/cookies and
/// secrets/feeds. The phone signs in anonymously and can read anything only once the Mac paired it.
///
/// Unlike the Android app, the iPhone never writes a video's `phone` field (the Android phone
/// owns it) and has no push token: it polls instead.
public struct Remote: Sendable {
    public let config: FirebaseConfig
    public let auth: FirebaseAuth
    public let firestore: FirestoreClient

    public init(config: FirebaseConfig, session: URLSession? = nil, tokenStore: TokenStore, firebaseGuard: FirebaseGuard? = nil) {
        let session = session ?? HTTPClient.makeSession()
        self.config = config
        auth = FirebaseAuth(config: config, session: session, store: tokenStore, firebaseGuard: firebaseGuard)
        firestore = FirestoreClient(projectId: config.projectId, auth: auth, session: session, firebaseGuard: firebaseGuard)
    }

    public var projectId: String { config.projectId }

    public func uid() async -> String? { await auth.uid }

    public func signOut() async { await auth.signOut() }

    // Pairing

    /// Files a pairing request under the invite's code and waits until the Mac has added this
    /// phone (members/{uid} becomes readable). Throws when it doesn't within `timeout`.
    public func pair(_ invite: Invite, deviceName: String, timeout: Duration = .seconds(60),
                     pollEvery interval: Duration = .milliseconds(1_500)) async throws {
        guard invite.projectId == projectId else {
            throw StowError.pairing("This QR code is for Firebase project \(invite.projectId), but the app is built for \(projectId).")
        }
        let uid = try await auth.signIn()
        do {
            try await firestore.commit([.set("pairing/\(invite.code)", ["uid": .string(uid), "name": .string(deviceName), "fcmToken": .null])])
        } catch StowError.notPaired {
            // The rules only let a request be created: this code was used before (a retry after
            // a timeout, or another phone). The Mac may have added this phone meanwhile.
            if (try? await firestore.get("members/\(uid)")) != nil { return }
            throw StowError.pairing("This pairing code was already used. On the Mac, open Pair a Phone again and scan the new code.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try await Task.sleep(for: interval)
            do {
                if try await firestore.get("members/\(uid)") != nil { return }
            } catch StowError.notPaired {
                // Not yet: the Mac hasn't added this phone.
            }
        }
        throw StowError.pairing("The Mac didn't confirm the pairing. Is Stow running on it, with the QR code still open?")
    }

    /// Whether the Mac still has this phone as a member.
    public func isMember() async throws -> Bool {
        guard let uid = await auth.uid else { return false }
        do {
            return try await firestore.get("members/\(uid)") != nil
        } catch StowError.notPaired {
            return false
        }
    }

    // Reading

    /// Every video sent to the phone.
    public func videos() async throws -> [SentVideo] {
        try await firestore.list("videos").compactMap(Self.sentVideo)
    }

    /// The Mac's channels with their newest videos, in the Mac's order.
    public func channels() async throws -> [Channel] {
        try await firestore.list("channels").map(Self.channel).sorted { $0.order < $1.order }
    }

    /// One sent video; nil when there's no such document.
    public func video(_ id: String) async throws -> SentVideo? {
        try await firestore.get("videos/\(id)").flatMap(Self.sentVideo)
    }

    /// What changed in a collection since a cursor: the changed documents' values and the new cursor.
    public struct Changes<Value: Sendable>: Sendable {
        public var values: [Value]
        /// The latest `updatedAt` seen, as Firestore wrote it; pass it to the next call.
        public var cursor: String?
    }

    /// Videos sent or changed after `cursor`; with no cursor, every video (a full list, which is
    /// also how deletions show). Firestore bills each document read, so polls ask for changes only.
    public func videoChanges(after cursor: String?) async throws -> Changes<SentVideo> {
        let documents = try await cursor == nil ? firestore.list("videos") : firestore.changed("videos", after: cursor)
        return Changes(values: documents.compactMap(Self.sentVideo), cursor: Self.latest(documents) ?? cursor)
    }

    /// Channels changed after `cursor`; with no cursor, every channel.
    public func channelChanges(after cursor: String?) async throws -> Changes<Channel> {
        let documents = try await cursor == nil ? firestore.list("channels") : firestore.changed("channels", after: cursor)
        return Changes(values: documents.map(Self.channel), cursor: Self.latest(documents) ?? cursor)
    }

    static func latest(_ documents: [FirestoreDocument]) -> String? {
        documents.compactMap { document -> (String, Date)? in
            guard let text = document["updatedAt"]?.timestamp, let date = document["updatedAt"]?.date else { return nil }
            return (text, date)
        }.max { $0.1 < $1.1 }?.0
    }

    /// The YouTube cookies (Netscape cookies.txt), decrypted; nil when the Mac hasn't shared any.
    public func cookies(key: Data) async throws -> Data? {
        guard let sealed = try await firestore.get("secrets/cookies")?["sealed"]?.string else { return nil }
        return try Crypto.open(base64: sealed, key: key)
    }

    /// YouTube's Home and Subscriptions as the Mac last read them, still sealed; nil until shared.
    public func sealedAccountFeeds() async throws -> String? {
        try await firestore.get("secrets/feeds")?["sealed"]?.string
    }

    public func shared() async throws -> SharedState {
        guard let document = try await firestore.get("shared/phone") else { return SharedState() }
        return Self.shared(document)
    }

    // Writing (only the fields the rules let a phone change)

    /// Changes the groups on top of the latest in Firestore (the Mac may have just changed them).
    public func editGroups(_ change: @Sendable ([ChannelGroup]) -> [ChannelGroup]) async throws {
        try await firestore.runTransaction { transaction in
            let current = try await firestore.get("shared/phone", transaction: transaction).map(Self.shared)?.groups ?? []
            return [.merge("shared/phone", ["groups": Self.groupsValue(change(current)), "groupsUpdatedBy": "phone"])]
        }
    }

    /// Asks the Mac to check everything now; returns the request's server time.
    public func requestRefresh() async throws -> Date {
        let result = try await firestore.commit([.merge("shared/phone", [:], serverTimestamps: ["refreshRequestedAt"])])
        if let time = result.serverTimes.first?.first { return time }
        return try await shared().refreshRequestedAt ?? .now
    }

    /// Asks for a video the Mac didn't send (picked from a channel page or a search): files
    /// videos/{id}. Returns the server's sentAt. A video that already has a document is refused
    /// (the rules allow only creating one): that throws `.notPaired`, so callers check with `video(_:)`.
    @discardableResult
    public func requestDownload(_ video: Video, watched: Bool = false) async throws -> Date? {
        let result = try await firestore.commit([.set("videos/\(video.id)", [
            "channelId": .string(video.channelId),
            "channelTitle": .string(video.channelTitle),
            "title": .string(video.title),
            "publishedAt": video.publishedAt.map(FirestoreValue.date) ?? .null,
            "thumbnailURL": .optional(video.thumbnailURL),
            "isMembersOnly": .bool(video.isMembersOnly),
            "liveStatus": .optional(video.liveStatus),
            "sentBy": "phone",
            "watched": .bool(watched),
            "updatedBy": "phone",
        ], serverTimestamps: ["sentAt", "updatedAt"])])
        return result.serverTimes.first?.first ?? result.commitTime
    }

    public func setWatched(_ id: String, watched: Bool) async throws {
        var fields: [String: FirestoreValue] = ["watched": .bool(watched), "updatedBy": "phone"]
        var stamps = ["updatedAt"]
        if watched {
            fields["watchedBy"] = "phone"
            stamps.append("watchedAt")
        } else {
            fields["watchedAt"] = .null
            fields["watchedBy"] = .null
        }
        try await firestore.commit([.update("videos/\(id)", fields, serverTimestamps: stamps)])
    }

    // Decoding

    static func sentVideo(_ document: FirestoreDocument) -> SentVideo? {
        guard let title = document["title"]?.string else { return nil }
        let video = Video(
            id: document.id,
            channelId: document["channelId"]?.string ?? "",
            channelTitle: document["channelTitle"]?.string ?? "",
            title: title,
            publishedAt: document["publishedAt"]?.date,
            thumbnailURL: document["thumbnailURL"]?.string,
            isMembersOnly: document["isMembersOnly"]?.bool ?? false,
            liveStatus: document["liveStatus"]?.string,
            durationSeconds: document["duration"]?.int
        )
        return SentVideo(video: video, sentAt: document["sentAt"]?.date, sentBy: document["sentBy"]?.string,
                         watched: document["watched"]?.bool ?? false)
    }

    static func channel(_ document: FirestoreDocument) -> Channel {
        let id = document.id
        let title = document["title"]?.string ?? id
        let recent = (document["recent"]?.array ?? []).compactMap { value -> RecentVideo? in
            guard let entry = value.map, let videoId = entry["id"]?.string else { return nil }
            return RecentVideo(video: Video(
                id: videoId,
                channelId: id,
                channelTitle: title,
                title: entry["title"]?.string ?? videoId,
                publishedAt: entry["publishedAt"]?.date,
                thumbnailURL: entry["thumbnailURL"]?.string,
                isMembersOnly: entry["isMembersOnly"]?.bool ?? false,
                liveStatus: entry["liveStatus"]?.string,
                durationSeconds: entry["duration"]?.int
            ), watched: entry["watched"]?.bool ?? false)
        }
        return Channel(id: id, title: title, handle: document["handle"]?.string, avatarURL: document["avatarURL"]?.string,
                       order: document["order"]?.int ?? 0, recent: recent)
    }

    static func shared(_ document: FirestoreDocument) -> SharedState {
        let groups = (document["groups"]?.array ?? []).compactMap { value -> ChannelGroup? in
            guard let group = value.map, let id = group["id"]?.string else { return nil }
            let channels = (group["channels"]?.array ?? []).compactMap { value -> GroupChannel? in
                guard let channel = value.map, let channelId = channel["id"]?.string else { return nil }
                return GroupChannel(id: channelId, title: channel["title"]?.string ?? channelId)
            }
            return ChannelGroup(id: id, name: group["name"]?.string ?? "Group", channels: channels)
        }
        return SharedState(groups: groups, refreshRequestedAt: document["refreshRequestedAt"]?.date,
                           refreshHandledAt: document["refreshHandledAt"]?.date)
    }

    static func groupsValue(_ groups: [ChannelGroup]) -> FirestoreValue {
        .array(groups.map { group in
            .map(["id": .string(group.id), "name": .string(group.name),
                  "channels": .array(group.channels.map { .map(["id": .string($0.id), "title": .string($0.title)]) })])
        })
    }
}
