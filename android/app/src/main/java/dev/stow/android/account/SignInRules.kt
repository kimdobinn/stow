package dev.stow.android.account

/** The web sign-in's rules (the Mac's, plus what Android's WebView needs), pure so they're tested. */
object SignInRules {
    /** The same page the Mac opens. */
    const val LOGIN_URL = "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/"
    /** Where the exported cookies are read from: www before m, so www's copy wins. */
    val EXPORT_URLS = listOf("https://www.youtube.com", "https://m.youtube.com", "https://accounts.google.com", "https://www.google.com")
    const val HELP = "Export cookies.txt for youtube.com from a desktop browser, ideally from a private window you then close, " +
        "so YouTube doesn't rotate them. Stow keeps only the youtube.com and google.com cookies."

    /** WebView's own user agent without the tokens Google flags embedded browsers by ("; wv", "Version/4.0"): it reads as Chrome for Android. */
    fun userAgent(webViewDefault: String): String = webViewDefault.replace("; wv", "").replace(" Version/4.0", "")

    /** Google refuses to sign in inside this web view. */
    fun isBlocked(url: String?, title: String?): Boolean =
        url.orEmpty().substringBefore('?').contains("/signin/rejected") || title.orEmpty().contains("may not be secure", ignoreCase = true)

    /** Signed in: on youtube.com, the page done loading, and a session that wasn't there when the screen opened. */
    fun isDone(host: String?, loading: Boolean, fingerprint: String?, initialFingerprint: String?): Boolean =
        host.orEmpty().lowercase().endsWith("youtube.com") && !loading && fingerprint != null && fingerprint != initialFingerprint

    /**
     * One sign-in screen's sessions: each new one is taken once. After YouTube refused one, the
     * web view starts again from Google's login; that session's fingerprint is remembered, so it
     * doesn't count again (if any of it survived the wipe), but a new sign-in does.
     */
    class Sessions {
        /** The last session taken (and, if the screen is still open, refused). */
        var taken: String? = null
            private set

        /** Whether this is a new session to export; it's remembered when it is. */
        fun take(host: String?, loading: Boolean, fingerprint: String?): Boolean {
            if (!isDone(host, loading, fingerprint, taken)) return false
            taken = fingerprint
            return true
        }
    }
}
