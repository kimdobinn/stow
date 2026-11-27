import Foundation

/// Sample channels and videos for demo mode (see `Demo`), the same as the Android app's: public
/// music videos, so screenshots and the simulator never need Firebase.
public enum DemoData {
    private static func daysAgo(_ days: Double, from now: Date) -> Date { now.addingTimeInterval(-days * 86_400) }
    private static func thumb(_ id: String) -> String { "https://i.ytimg.com/vi/\(id)/hqdefault.jpg" }

    private static func jawed(_ now: Date) -> [Video] {
        [Video(id: "jNQXAC9IVRw", channelId: "UC4QobU6STFB0P71PMvOGN5A", channelTitle: "jawed", title: "Me at the zoo",
               publishedAt: daysAgo(0.2, from: now), thumbnailURL: thumb("jNQXAC9IVRw"), isMembersOnly: false)]
    }

    private static func rick(_ now: Date) -> [Video] {
        let channel = "UCuAXFkgsw1L7xaCfnd5JJOw"
        return [
            Video(id: "dQw4w9WgXcQ", channelId: channel, channelTitle: "Rick Astley", title: "Rick Astley - Never Gonna Give You Up (Official Video)",
                  publishedAt: daysAgo(1.5, from: now), thumbnailURL: thumb("dQw4w9WgXcQ"), isMembersOnly: false),
            Video(id: "yPYZpwSpKmA", channelId: channel, channelTitle: "Rick Astley", title: "Rick Astley - Together Forever (Official Video)",
                  publishedAt: daysAgo(9, from: now), thumbnailURL: thumb("yPYZpwSpKmA"), isMembersOnly: false),
            Video(id: "AC3Ejf7vPEY", channelId: channel, channelTitle: "Rick Astley", title: "Rick Astley - Cry For Help (Official Video)",
                  publishedAt: daysAgo(20, from: now), thumbnailURL: thumb("AC3Ejf7vPEY"), isMembersOnly: true),
            Video(id: "lYBUbBu4W08", channelId: channel, channelTitle: "Rick Astley", title: "Rick Astley live from the studio",
                  publishedAt: daysAgo(3, from: now), thumbnailURL: thumb("lYBUbBu4W08"), isMembersOnly: false,
                  liveStatus: "wasLive", durationSeconds: 5_400),
        ]
    }

    public static func channels(now: Date = .now) -> [Channel] {
        [
            Channel(id: "UC4QobU6STFB0P71PMvOGN5A", title: "jawed", handle: "@jawed", avatarURL: nil, order: 0,
                    recent: jawed(now).map { RecentVideo(video: $0, watched: false) }),
            Channel(id: "UCuAXFkgsw1L7xaCfnd5JJOw", title: "Rick Astley", handle: "@RickAstleyYT", avatarURL: nil, order: 1,
                    recent: rick(now).enumerated().map { RecentVideo(video: $1, watched: $0 == 1) }),
        ]
    }

    private static func yt(_ id: String, _ channelId: String, _ channel: String, _ title: String, _ seconds: Int) -> Video {
        Video(id: id, channelId: channelId, channelTitle: channel, title: title, publishedAt: nil, thumbnailURL: thumb(id),
              isMembersOnly: false, durationSeconds: seconds)
    }

    /// What the Mac would share of YouTube's Home and Subscriptions.
    public static func youtubeFeeds(now: Date = .now) -> YouTubeFeeds {
        var together = rick(now)[1]
        together.durationSeconds = 211
        return YouTubeFeeds(
            recommended: [
                yt("9bZkp7q19f0", "UCrDkAvwZum-UTjHmzDI2iIw", "officialpsy", "PSY - GANGNAM STYLE(강남스타일) M/V", 252),
                yt("kJQP7kiw5Fk", "UCLp8RBhQHu9wSsq62j_Md6A", "Luis Fonsi", "Luis Fonsi - Despacito ft. Daddy Yankee", 282),
                yt("JGwWNGJdvx8", "UC0C-w0YjGpqDXGB8IHb662A", "Ed Sheeran", "Ed Sheeran - Shape of You (Official Music Video)", 263),
            ],
            subscriptions: [
                together,
                yt("OPf0YbXqDm0", "UCdKDCoP9NM48pyhcKeVB7cQ", "Mark Ronson", "Mark Ronson - Uptown Funk (Official Video) ft. Bruno Mars", 271),
            ]
        )
    }

    /// Sent to the phone, so these download right away. sentAt is fixed, not relative to now:
    /// a later sentAt means "sent again", which would bring back a deleted download at every launch.
    public static func sent(now: Date = .now) -> [SentVideo] {
        [SentVideo(video: jawed(now)[0], sentAt: sentAt, sentBy: "mac", watched: false)]
    }

    static let sentAt = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
}
