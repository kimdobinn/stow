#if DEBUG
import Foundation

/// `Stow --phone-restore` (Debug builds only): rewrites the phone's Firestore data (sent videos
/// with their watched and download status, channels with recent videos, sealed cookies) from
/// the installed app's state.json, which it only reads. Then wakes the phones.
@MainActor
enum PhoneRestore {
    static let argument = "--phone-restore"

    static func run() async -> Bool {
        do {
            let store = Store(directory: AppPaths.supportDirectory)
            let state = try store.loadState()
            let settings = try store.loadSettings()
            let backend = try FirebaseBackend(keyFile: AppPaths.firebaseKeyFile)
            let watched = Set(state.watchedIds)
            let known = Dictionary((state.inbox.map(\.video) + state.recentVideos.values.flatMap { $0 }).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })

            for reason in [PhoneSendReason.manual, .auto] {
                let videos = state.phone.sent.filter { $0.value.reason == reason }.keys.compactMap { known[$0] }
                guard !videos.isEmpty else { continue }
                try await backend.sendVideos(videos, reason: reason, watched: watched.intersection(videos.map(\.id)))
                print("restored \(videos.count) \(reason.rawValue) videos")
            }
            let downloads: [FirestoreWrite] = state.phone.sent.compactMap { id, entry in
                guard known[id] != nil, let download = entry.download else { return nil }
                return .merge(path: "videos/\(id)", fields: ["phone": .map([
                    "state": .string(download.state.rawValue), "error": .optional(download.error)])])
            }
            try await backend.firestoreForTests.commit(downloads)
            print("restored \(downloads.count) download states")

            let feeds = settings.channels.map { channel in
                let recent = Array((state.recentVideos[channel.id] ?? [])
                    .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                    .prefix(PhoneSync.recentPerChannel))
                return PhoneChannelFeed(channel: channel, recent: recent, watched: watched.intersection(recent.map(\.id)))
            }
            try await backend.saveChannels(feeds, removing: [])
            print("restored \(feeds.count) channels")

            let key = try PairingKey.loadOrCreate(at: AppPaths.pairingKeyFile)
            try await backend.saveCookies(sealed: key.seal(Data(contentsOf: AppPaths.cookiesFile)))
            print("restored cookies")

            for member in try await backend.members() {
                if let token = member.fcmToken {
                    print("\(member.name): \(try await backend.push(["type": "sync"], to: token) ? "woken" : "token invalid")")
                }
            }
            return true
        } catch {
            print("failed: \(error.logDescription)")
            return false
        }
    }
}
#endif
