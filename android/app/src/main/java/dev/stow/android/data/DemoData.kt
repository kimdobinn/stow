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
        Channel("UC4QobU6STFB0P71PMvOGN5A", "jawed", "@jawed", null, true, 0, jawed.map { RecentVideo(it, false) }),
        Channel("UCuAXFkgsw1L7xaCfnd5JJOw", "Rick Astley", "@RickAstleyYT", null, false, 1,
                rick.mapIndexed { i, v -> RecentVideo(v, i == 1) }),
    )

    /** Sent to the phone, so these download right away. */
    val sent = listOf(SentVideo(jawed[0], daysAgo(0.1), "mac", false))
}
