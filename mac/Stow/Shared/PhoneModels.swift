import Foundation

// Phone sync (Firebase) types and the backend boundary. Core/PhoneSync depends only on these;
// Phone/FirebaseBackend implements PhoneBackend against Firestore and FCM.
//
// Firestore layout (see firebase/firestore.rules):
//   members/{uid}     paired phones: name, fcmToken, pairedAt (the Mac adds and removes them)
//   pairing/{code}    a phone's pairing request: uid, name, fcmToken (the Mac deletes it)
//   channels/{id}     the Mac's channels: title, handle, avatarURL, phone, morning, order,
//                     recent [{id, title, publishedAt, thumbnailURL, isMembersOnly, liveStatus,
//                     watched}]; the phone may switch `phone` (auto-download) on or off
//   videos/{id}       videos sent to the phone: metadata, sentAt, sentBy, watched…,
//                     phone {state, error} (written by the phone), updatedAt, updatedBy.
//                     The phone creates one itself (sentBy "phone") to download a video.
//   secrets/cookies   the YouTube cookies, sealed with the pairing key

/// A paired phone.
struct PhoneMember: Codable, Hashable, Identifiable, Sendable {
    /// The phone's Firebase Auth uid.
    var id: String
    var name: String
    var fcmToken: String?
    var pairedAt: Date?
}

/// A phone that scanned the pairing QR code.
struct PairingRequest: Equatable, Sendable {
    var uid: String
    var name: String
    var fcmToken: String?
}

enum PhoneDownloadState: String, Codable, Sendable {
    case queued, downloading, downloaded, failed
    /// Downloaded, then deleted on the phone.
    case deleted
}

/// What the phone reported about a video it was sent.
struct PhoneDownload: Codable, Equatable, Sendable {
    var state: PhoneDownloadState
    var error: String?
}

/// Why a video was sent to the phone.
enum PhoneSendReason: String, Codable, Sendable {
    /// A new video of a channel with "phone" on.
    case auto
    /// "Send to Phone".
    case manual
}

/// What the phone sees of a channel: its settings and newest videos.
struct PhoneChannelFeed: Equatable, Sendable {
    var channel: Channel
    /// Newest first.
    var recent: [Video]
    /// Which of `recent` are watched.
    var watched: Set<String>
}

/// A channels/{id} document changed since the last poll.
struct PhoneChannelChange: Equatable, Sendable {
    var id: String
    /// Auto-download (the channel's `phone` setting).
    var phone: Bool?
    var updatedBy: String?
    var updatedAt: String
}

/// A videos/{id} document changed since the last poll.
struct PhoneVideoChange: Equatable, Sendable {
    var id: String
    var watched: Bool?
    var download: PhoneDownload?
    /// "mac" or "phone".
    var updatedBy: String?
    /// Server time of the change, passed back as the next poll's cursor.
    var updatedAt: String
}

protocol PhoneBackend: Sendable {
    var projectId: String { get }

    /// Paired phones. Throws `.network` (also when Firestore isn't set up) or `.parse` (bad key).
    func members() async throws -> [PhoneMember]
    /// The request filed under `code`, deleting it; nil when there's none yet.
    func takePairingRequest(code: String) async throws -> PairingRequest?
    func addMember(_ member: PhoneMember) async throws
    func removeMember(id: String) async throws

    /// Writes every channel (with its position and recent videos) and deletes `removing`.
    func saveChannels(_ feeds: [PhoneChannelFeed], removing: [String]) async throws
    /// channels/{id} changes after `cursor` (all when nil), oldest first.
    func channelChanges(after cursor: String?) async throws -> [PhoneChannelChange]
    /// Creates or refreshes videos/{id} for each video, marking it requested now.
    func sendVideos(_ videos: [Video], reason: PhoneSendReason, watched: Set<String>) async throws
    /// Sets `watched` on existing videos/{id} documents.
    func setWatched(_ watched: [String: Bool]) async throws
    /// videos/{id} changes after `cursor` (all when nil), oldest first.
    func videoChanges(after cursor: String?) async throws -> [PhoneVideoChange]
    /// The cookies sealed with the pairing key.
    func saveCookies(sealed: Data) async throws
    /// A high-priority data message. Returns false when the token is no longer valid.
    func push(_ data: [String: String], to token: String) async throws -> Bool
}

/// A video Stow sent to the phone.
struct PhoneSentVideo: Codable, Equatable, Sendable {
    var sentAt: Date
    var reason: PhoneSendReason
    /// The watched value Firestore has (last written or read), so changes on either side show.
    var watched: Bool
    var download: PhoneDownload?
}

struct PhonePendingSend: Codable, Equatable, Sendable {
    var id: String
    var reason: PhoneSendReason
}

/// Phone sync's part of state.json.
struct PhoneSyncState: Codable, Equatable, Sendable {
    /// Paired phones, as last read from Firestore.
    var members: [PhoneMember] = []
    /// videoId -> what the phone knows about it.
    var sent: [String: PhoneSentVideo] = [:]
    /// Videos to send at the next sync, oldest first.
    var pending: [PhonePendingSend] = []
    /// The newest videos/{id} change already read (Firestore server time).
    var cursor: String?
    /// The newest channels/{id} change already read.
    var channelCursor: String?
    /// Fingerprint of the channels last written, and their ids.
    var channelsHash: String?
    var syncedChannelIds: [String] = []
    /// Fingerprint of the cookies last uploaded.
    var cookiesHash: String?
    var lastSync: Date?

    static let empty = PhoneSyncState()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case members, sent, pending, cursor, channelCursor, channelsHash, syncedChannelIds, cookiesHash, lastSync
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = (try? c.decodeIfPresent([PhoneMember].self, forKey: .members)) ?? []
        sent = (try? c.decodeIfPresent([String: PhoneSentVideo].self, forKey: .sent)) ?? [:]
        pending = (try? c.decodeIfPresent([PhonePendingSend].self, forKey: .pending)) ?? []
        cursor = try? c.decodeIfPresent(String.self, forKey: .cursor)
        channelCursor = try? c.decodeIfPresent(String.self, forKey: .channelCursor)
        channelsHash = try? c.decodeIfPresent(String.self, forKey: .channelsHash)
        syncedChannelIds = (try? c.decodeIfPresent([String].self, forKey: .syncedChannelIds)) ?? []
        cookiesHash = try? c.decodeIfPresent(String.self, forKey: .cookiesHash)
        lastSync = try? c.decodeIfPresent(Date.self, forKey: .lastSync)
    }
}
