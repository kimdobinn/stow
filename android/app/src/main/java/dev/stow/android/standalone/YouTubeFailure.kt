package dev.stow.android.standalone

/** What went wrong in a yt-dlp run, from its output (a port of the Mac's `YTDLP.classify`). */
object YouTubeFailure {
    enum class Kind {
        /** Cookies missing, invalid or rotated: YouTube wants a sign-in. */
        AUTH,
        /** The video, playlist or tab doesn't exist or can't be viewed. */
        UNAVAILABLE,
        NETWORK,
        OTHER,
    }

    private val auth = listOf("cookies are no longer valid", "--cookies for the authentication")
    private val unavailable = listOf("does not exist", "http error 404", "video unavailable", "this video is private",
                                     "playlist type is unviewable", "this channel does not have")
    private val network = listOf("unable to download", "urlopen error", "failed to resolve", "nodename nor servname",
                                 "name or service not known", "temporary failure in name resolution",
                                 "network is unreachable", "connection reset", "connection refused", "timed out",
                                 "http error 429", "http error 5")

    /** Checked in this order: "Unable to download webpage: HTTP Error 404" is unavailable, not network. */
    fun classify(text: String?): Kind {
        val lowered = text.orEmpty().lowercase()
        return when {
            auth.any { it in lowered } -> Kind.AUTH
            unavailable.any { it in lowered } -> Kind.UNAVAILABLE
            network.any { it in lowered } -> Kind.NETWORK
            else -> Kind.OTHER
        }
    }

    /** A successful run whose warnings blame the cookies. */
    fun cookiesRejected(stderr: String?): Boolean = classify(stderr) == Kind.AUTH

    /** YouTube asked to slow down (HTTP 429). */
    fun isSlowDown(text: String?): Boolean = "http error 429" in text.orEmpty().lowercase()
}

/** A failed yt-dlp run: its (summarized) error output. */
class ToolFailure(val stderr: String) : Exception(stderr.lineSequence().firstOrNull { it.isNotBlank() }?.removePrefix("ERROR: ") ?: "yt-dlp failed") {
    val kind: YouTubeFailure.Kind get() = YouTubeFailure.classify(stderr)
}

/** YouTube answered 429 or 5xx (or yt-dlp says it did): stop for now and back off. */
class SlowDown(message: String, val status: Int = 429) : Exception(message)

/** YouTube no longer accepts the saved sign-in. */
class SignedOutByYouTube : Exception("YouTube signed you out.")
