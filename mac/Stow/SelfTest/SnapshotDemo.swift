#if DEBUG
import Foundation

/// `Stow --snapshot <dir> --demo`: well-known public music videos instead of your own channels,
/// for screenshots you can share (the README's).
enum SnapshotDemo {
    static let argument = "--demo"

    static func write(to store: Store, now: Date = .now) throws {
        func channel(_ id: String, _ title: String, _ handle: String, morning: Bool = true) -> Channel {
            Channel(info: ChannelInfo(id: id, title: title, handle: handle), morning: morning)
        }
        let rick = channel("UCuAXFkgsw1L7xaCfnd5JJOw", "Rick Astley", "@RickAstleyYT")
        let psy = channel("UCrDkAvwZum-UTjHmzDI2iIw", "officialpsy", "@officialpsy")
        let fonsi = channel("UCLp8RBhQHu9wSsq62j_Md6A", "Luis Fonsi", "@LuisFonsi", morning: false)
        let ronson = channel("UCBUjWT3bXu1Yy3W3bwbV7aA", "Mark Ronson", "@MarkRonson")
        let jawed = channel("UC4QobU6STFB0P71PMvOGN5A", "jawed", "@jawed")
        let channels = [rick, psy, fonsi, ronson, jawed]

        func video(_ id: String, _ channel: Channel, _ title: String, hoursAgo: Double, members: Bool = false,
                   streamed: TimeInterval? = nil) -> Video {
            Video(id: id, channelId: channel.id, channelTitle: channel.title, title: title,
                  publishedAt: now.addingTimeInterval(-hoursAgo * 3600),
                  thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"), isMembersOnly: members,
                  liveStatus: streamed == nil ? .none : .wasLive, duration: streamed)
        }
        let inbox = [
            video("kJQP7kiw5Fk", fonsi, "Luis Fonsi - Despacito ft. Daddy Yankee", hoursAgo: 2),
            video("OPf0YbXqDm0", ronson, "Mark Ronson - Uptown Funk (Official Video) ft. Bruno Mars", hoursAgo: 5),
            video("dQw4w9WgXcQ", rick, "Rick Astley - Never Gonna Give You Up (Official Video)", hoursAgo: 26),
        ]
        let recent: [String: [Video]] = [
            rick.id: [video("lYBUbBu4W08", rick, "Rick Astley live from the studio", hoursAgo: 72, streamed: 5400),
                      video("yPYZpwSpKmA", rick, "Rick Astley - Together Forever (Official Video)", hoursAgo: 216),
                      video("AC3Ejf7vPEY", rick, "Rick Astley - Cry For Help (Official Video)", hoursAgo: 480, members: true)],
            psy.id: [video("9bZkp7q19f0", psy, "PSY - GANGNAM STYLE(강남스타일) M/V", hoursAgo: 30),
                     video("ASO_zypdnsQ", psy, "PSY - GENTLEMAN M/V", hoursAgo: 300)],
            jawed.id: [video("jNQXAC9IVRw", jawed, "Me at the zoo", hoursAgo: 4)],
        ]
        var settings = AppSettings.default
        settings.channels = channels
        try store.save(settings)
        var state = AppState(seenVideoIds: [:], inbox: inbox.enumerated().map { InboxItem(video: $1, foundAt: now.addingTimeInterval(-Double($0) * 600)) },
                             recentVideos: recent,
                             lastCheck: CheckResult(trigger: .scheduled, startedAt: now.addingTimeInterval(-240),
                                                    finishedAt: now.addingTimeInterval(-230), channelsChecked: channels.count,
                                                    newVideos: 2, errors: []))
        state.memberAccess = ["AC3Ejf7vPEY": .watchable]
        try store.save(state)
    }
}
#endif
