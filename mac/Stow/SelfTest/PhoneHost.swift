#if DEBUG
import Foundation

/// `Stow --phone-host <invite file> [seconds]` (Debug builds only): plays the Mac for a real
/// phone or emulator without touching the installed app's state. Writes a pairing link to
/// <invite file>, pairs whoever files a request, shares the cookies, sends a short public video
/// with a push, then prints every change the phone reports until the time is up, and cleans up.
@MainActor
enum PhoneHost {
    static let argument = "--phone-host"
    /// "Me at the zoo", 19 seconds.
    static let testVideo = Video(id: "jNQXAC9IVRw", channelId: "UC4QobU6STFB0P71PMvOGN5A", channelTitle: "jawed",
                                 title: "Me at the zoo", publishedAt: Date(timeIntervalSince1970: 1_114_000_000),
                                 thumbnailURL: URL(string: "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg"),
                                 isMembersOnly: false, liveStatus: .none)
    /// A second recent video the phone can pick from the channel page (3:33).
    static let channelVideo = Video(id: "dQw4w9WgXcQ", channelId: "UC4QobU6STFB0P71PMvOGN5A", channelTitle: "jawed",
                                    title: "Never Gonna Give You Up", publishedAt: Date(timeIntervalSince1970: 1_256_000_000),
                                    thumbnailURL: URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"),
                                    isMembersOnly: false, liveStatus: .none)

    static func run() async -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: argument), args.indices.contains(index + 1) else {
            print("usage: Stow --phone-host <invite file> [seconds]")
            return false
        }
        let inviteFile = URL(filePath: args[index + 1])
        let seconds = args.indices.contains(index + 2) ? Double(args[index + 2]) ?? 300 : 300
        let scratch = FileManager.default.temporaryDirectory.appending(path: "stow-phone-host-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: inviteFile)
        }
        var member: PhoneMember?
        let backend: FirebaseBackend
        do {
            backend = try FirebaseBackend(keyFile: AppPaths.firebaseKeyFile)
        } catch {
            print("no key: \(error.logDescription)")
            return false
        }
        do {
            // Its cleanup deletes shared data, so never run it next to a real paired phone.
            let paired = try await backend.members()
            guard paired.isEmpty else {
                print("REFUSED \(paired.map(\.name).joined(separator: ", ")) is paired; unpair first")
                return false
            }
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let key = try PairingKey.loadOrCreate(at: scratch.appending(path: "pairing-key"))
            let invite = PairingInvite.make(projectId: backend.projectId, key: key)
            try Data(invite.url.absoluteString.utf8).write(to: inviteFile)
            print("INVITE written; waiting for a phone")

            let deadline = Date.now.addingTimeInterval(seconds)
            while member == nil, Date.now < deadline {
                try await Task.sleep(for: .seconds(1))
                if let request = try await backend.takePairingRequest(code: invite.code) {
                    let paired = PhoneMember(id: request.uid, name: request.name, fcmToken: request.fcmToken, pairedAt: .now)
                    try await backend.addMember(paired)
                    member = paired
                    print("PAIRED \(paired.name) (push token: \(paired.fcmToken == nil ? "none" : "yes"))")
                }
            }
            guard let member else {
                print("TIMEOUT no phone paired")
                return false
            }
            if let cookies = try? Data(contentsOf: AppPaths.cookiesFile) {
                try await backend.saveCookies(sealed: key.seal(cookies))
                print("COOKIES shared")
            }
            let channel = Channel(info: ChannelInfo(id: testVideo.channelId, title: "jawed",
                                                    avatarURL: URL(string: "https://yt3.ggpht.com/ytc/AIdro_kvhH1J-xbeJwsHEP5IoWqv-wn9yRRj8mjRf6FT6lb-dCQ=s88-c-k-c0x00ffffff-no-rj")))
            try await backend.saveChannels([PhoneChannelFeed(channel: channel, recent: [Self.channelVideo, testVideo], watched: [])],
                                           removing: [])
            try await backend.sendVideos([testVideo], reason: .manual, watched: [])
            if let token = member.fcmToken {
                let delivered = try await backend.push(["type": "videos", "ids": testVideo.id], to: token)
                print("PUSH \(delivered ? "sent" : "token invalid")")
            }
            var cursor: String?
            var channelCursor: String?
            while Date.now < deadline {
                try await Task.sleep(for: .seconds(2))
                for change in try await backend.channelChanges(after: channelCursor) {
                    channelCursor = change.updatedAt
                    if change.updatedBy == "phone" { print("CHANNEL \(change.id) auto-download=\(change.phone.map(String.init) ?? "-")") }
                }
                for change in try await backend.videoChanges(after: cursor) {
                    cursor = change.updatedAt
                    guard change.updatedBy == "phone" else { continue }
                    print("CHANGE \(change.id) watched=\(change.watched.map(String.init) ?? "-") download=\(change.download.map { "\($0.state.rawValue)\($0.error.map { " (\($0))" } ?? "")" } ?? "-")")
                }
            }
            print("DONE")
        } catch {
            print("ERROR \(error.logDescription)")
        }
        // Clean up everything this run created.
        do {
            try await backend.saveChannels([], removing: [testVideo.channelId])
            if let member { try await backend.removeMember(id: member.id) }
            try await backend.cleanUpTest(videoId: testVideo.id)
            try await backend.cleanUpTest(videoId: Self.channelVideo.id)
            print("CLEANED")
        } catch {
            print("cleanup failed: \(error.logDescription)")
        }
        return true
    }
}

extension FirebaseBackend {
    /// Deletes the test video and the shared cookies.
    func cleanUpTest(videoId: String) async throws {
        try await firestoreForTests.commit([.delete(path: "videos/\(videoId)"), .delete(path: "secrets/cookies")])
    }
}
#endif
