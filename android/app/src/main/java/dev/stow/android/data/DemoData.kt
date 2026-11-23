package dev.stow.android.data

import java.util.Date

/** Sample channels and videos for the debug demo mode (see Repository.demo). */
object DemoData {
    private fun daysAgo(days: Double) = Date(System.currentTimeMillis() - (days * 86_400_000).toLong())
    private fun thumb(id: String) = "https://i.ytimg.com/vi/$id/hqdefault.jpg"

    private val jawed = listOf(
        Video("jNQXAC9IVRw", "UC4QobU6STFB0P71PMvOGN5A", "jawed", "Me at the zoo", daysAgo(0.2), thumb("jNQXAC9IVRw"), false),
    )
    private val rick = listOf(
        Video("dQw4w9WgXcQ", "UCuAXFkgsw1L7xaCfnd5JJOw", "Rick Astley", "Rick Astley - Never Gonna Give You Up (Official Video)", daysAgo(1.5), thumb("dQw4w9WgXcQ"), false),
        Video("yPYZpwSpKmA", "UCuAXFkgsw1L7xaCfnd5JJOw", "Rick Astley", "Rick Astley - Together Forever (Official Video)", daysAgo(9.0), thumb("yPYZpwSpKmA"), false),
        Video("AC3Ejf7vPEY", "UCuAXFkgsw1L7xaCfnd5JJOw", "Rick Astley", "Rick Astley - Cry For Help (Official Video)", daysAgo(20.0), thumb("AC3Ejf7vPEY"), true),
    )

    val channels = listOf(
        Channel("UC4QobU6STFB0P71PMvOGN5A", "jawed", "@jawed", null, 0, jawed.map { RecentVideo(it, false) }),
        Channel("UCuAXFkgsw1L7xaCfnd5JJOw", "Rick Astley", "@RickAstleyYT", null, 1,
                rick.mapIndexed { i, v -> RecentVideo(v, i == 1) }),
    )

    private fun yt(id: String, channelId: String, channel: String, title: String, seconds: Long) =
        Video(id, channelId, channel, title, null, thumb(id), false, durationSeconds = seconds)

    /** What the Mac would share of YouTube's Home and Subscriptions. */
    val youtubeFeeds = YouTubeFeeds(
        recommended = listOf(
            yt("9bZkp7q19f0", "UCrDkAvwZum-UTjHmzDI2iIw", "officialpsy", "PSY - GANGNAM STYLE(강남스타일) M/V", 252),
            yt("kJQP7kiw5Fk", "UCLp8RBhQHu9wSsq62j_Md6A", "Luis Fonsi", "Luis Fonsi - Despacito ft. Daddy Yankee", 282),
            yt("JGwWNGJdvx8", "UC0C-w0YjGpqDXGB8IHb662A", "Ed Sheeran", "Ed Sheeran - Shape of You (Official Music Video)", 263),
        ),
        subscriptions = listOf(
            rick[1].copy(durationSeconds = 211),
            yt("OPf0YbXqDm0", "UCdKDCoP9NM48pyhcKeVB7cQ", "Mark Ronson", "Mark Ronson - Uptown Funk (Official Video) ft. Bruno Mars", 271),
        ),
    )

    /** Sent to the phone, so these download right away. */
    val sent = listOf(SentVideo(jawed[0], daysAgo(0.1), "mac", false))
}
