package dev.stow.android.standalone

/** A yt-dlp run that worked: its standard output, and whether its warnings blamed the cookies. */
data class ToolOutput(val stdout: String, val cookiesRejected: Boolean = false) {
    /** The JSON line of a -J run. */
    val json: String get() = stdout.lineSequence().firstOrNull { it.trimStart().startsWith("{") } ?: "{}"
}

/**
 * yt-dlp, as the standalone checker uses it. `cookies` is cookies.txt text: the real tool writes
 * it to a fresh private temporary file for that one run (yt-dlp rewrites the file) and deletes it.
 * A failed run throws [ToolFailure] ([SlowDown] for HTTP 429), or IOException when it timed out.
 */
interface YouTubeTool {
    suspend fun run(args: List<String>, cookies: String?, timeoutMs: Long = LISTING_TIMEOUT_MS): ToolOutput

    companion object {
        const val LISTING_TIMEOUT_MS = 60_000L
        /** Flat listings have no dates unless asked: YouTube's "3 days ago" becomes an approximate timestamp. */
        const val APPROXIMATE_DATES = "youtubetab:approximate_date"
    }
}

/** yt-dlp --flat-playlist -J --playlist-end `count` `url`. */
suspend fun YouTubeTool.flat(url: String, count: Int, cookies: String?): ToolOutput =
    run(listOf("--flat-playlist", "-J", "--extractor-args", YouTubeTool.APPROXIMATE_DATES, "--playlist-end", count.toString(), url), cookies)

/** yt-dlp --simulate --mark-watched: YouTube records a view, as if it was played there. */
suspend fun YouTubeTool.markWatched(videoId: String, cookies: String): ToolOutput =
    run(listOf("--simulate", "--mark-watched", "--quiet", "https://www.youtube.com/watch?v=$videoId"), cookies)
