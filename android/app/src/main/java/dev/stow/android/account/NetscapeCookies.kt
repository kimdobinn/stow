package dev.stow.android.account

import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** One cookie as yt-dlp's cookies.txt holds it. `expiry` is in epoch seconds; null for a session cookie. */
data class Cookie(
    val domain: String,
    val name: String,
    val value: String,
    val path: String = "/",
    val secure: Boolean = true,
    val expiry: Long? = null,
    val httpOnly: Boolean = false,
) {
    /** A leading "." means the cookie also goes to subdomains. */
    val includeSubdomains: Boolean get() = domain.startsWith(".")
    val host: String get() = domain.removePrefix(".")
}

/**
 * Netscape cookies.txt, the format yt-dlp reads: export from the sign-in web view, import from a
 * file, and the Mac's signed-in test (a port of its `CookieExporter`).
 */
object NetscapeCookies {
    const val HEADER = "# Netscape HTTP Cookie File"
    /** Only these domains (and their subdomains) are kept. */
    val DOMAINS = listOf("youtube.com", "google.com")
    const val LOGIN_INFO = "LOGIN_INFO"
    /** yt-dlp treats a session as signed in only with LOGIN_INFO plus one of these on youtube.com. */
    val SAPISID_NAMES = setOf("SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID")
    /** Expiry written for session cookies (yt-dlp drops cookies that look expired). */
    const val SESSION_LIFETIME_SECONDS = 365L * 24 * 3600
    /** Android's fallback export has no expiries: it writes this far ahead. */
    const val FALLBACK_LIFETIME_SECONDS = 400L * 24 * 3600

    fun matches(domain: String, base: String): Boolean {
        val host = domain.removePrefix(".").lowercase()
        return host == base || host.endsWith(".$base")
    }

    fun isKept(cookie: Cookie): Boolean = DOMAINS.any { matches(cookie.domain, it) }

    private fun hasControlCharacters(cookie: Cookie) =
        listOf(cookie.domain, cookie.path, cookie.name, cookie.value).any { s -> s.any { it == '\t' || it == '\n' || it == '\r' } }

    /** cookies.txt text, header included: youtube.com and google.com only, sorted by (domain, path, name). */
    fun format(cookies: List<Cookie>, nowMs: Long): String {
        val sessionExpiry = nowMs / 1000 + SESSION_LIFETIME_SECONDS
        val lines = cookies.filter { isKept(it) && !hasControlCharacters(it) }
            .sortedWith(compareBy<Cookie>({ it.domain }, { it.path }, { it.name }))
            .map { c ->
                listOf(c.domain, if (c.includeSubdomains) "TRUE" else "FALSE", c.path, if (c.secure) "TRUE" else "FALSE",
                       (c.expiry ?: sessionExpiry).toString(), c.name, c.value).joinToString("\t")
            }
        return (listOf(HEADER, "") + lines).joinToString("\n") + "\n"
    }

    /**
     * The youtube.com and google.com cookies in cookies.txt `text`: `#HttpOnly_` lines count,
     * other comments and blank lines don't, and a line needs all 7 fields.
     */
    fun parse(text: String): List<Cookie> = text.lineSequence().mapNotNull { raw ->
        var line = raw.trimEnd('\r', '\n')
        var httpOnly = false
        if (line.startsWith("#HttpOnly_")) {
            line = line.removePrefix("#HttpOnly_")
            httpOnly = true
        }
        if (line.isBlank() || line.startsWith("#")) return@mapNotNull null
        val fields = line.split("\t")
        if (fields.size < 7) return@mapNotNull null
        val expiry = fields[4].trim().toLongOrNull()?.takeIf { it > 0 }
        Cookie(domain = fields[0].trim(), name = fields[5], value = fields.subList(6, fields.size).joinToString("\t"),
               path = fields[2].ifEmpty { "/" }, secure = fields[3].equals("TRUE", ignoreCase = true),
               expiry = expiry, httpOnly = httpOnly).takeIf(::isKept)
    }.toList()

    /**
     * The values of the youtube.com session cookies, or null when signed out: unexpired LOGIN_INFO
     * plus one of the SAPISID family. Changes when the user signs in again.
     */
    fun sessionFingerprint(cookies: List<Cookie>, nowMs: Long): String? {
        val now = nowMs / 1000
        val session = cookies.filter { c ->
            (c.name == LOGIN_INFO || c.name in SAPISID_NAMES) && matches(c.domain, "youtube.com") && (c.expiry?.let { it > now } ?: true)
        }.sortedWith(compareBy<Cookie>({ it.name }, { it.domain }, { it.value }))
        if (session.none { it.name == LOGIN_INFO } || session.none { it.name in SAPISID_NAMES }) return null
        return session.joinToString(";") { "${it.name}=${it.value}" }
    }

    fun isSignedIn(cookies: List<Cookie>, nowMs: Long): Boolean = sessionFingerprint(cookies, nowMs) != null

    /** When youtube.com's LOGIN_INFO runs out (epoch seconds), if the cookies say. */
    fun loginInfoExpiry(cookies: List<Cookie>): Long? =
        cookies.filter { it.name == LOGIN_INFO && matches(it.domain, "youtube.com") }.mapNotNull { it.expiry }.maxOrNull()

    /** A `Cookie:` header for `host`: every cookie whose domain covers it, first one per name. */
    fun header(cookies: List<Cookie>, host: String): String {
        val target = host.lowercase()
        val seen = HashSet<String>()
        return cookies.filter { c ->
            val domain = c.host.lowercase()
            target == domain || (c.includeSubdomains && target.endsWith(".$domain"))
        }.filter { seen.add(it.name) }.joinToString("; ") { "${it.name}=${it.value}" }
    }

    // Android's WebView

    private val expiresFormat: DateTimeFormatter = DateTimeFormatter.RFC_1123_DATE_TIME.withLocale(Locale.US)

    /**
     * One of `CookieManagerCompat.getCookieInfo`'s strings ("name=value; Domain=…; Path=…;
     * Expires=…; Secure; HttpOnly"), for a cookie set on `host`. Without Domain it's host-only.
     */
    fun parseCookieInfo(info: String, host: String, nowMs: Long): Cookie? {
        val parts = info.split(";").map { it.trim() }.filter { it.isNotEmpty() }
        val first = parts.firstOrNull() ?: return null
        val eq = first.indexOf('=')
        if (eq <= 0) return null
        val name = first.substring(0, eq).trim()
        val value = first.substring(eq + 1).trim()
        var domain: String? = null
        var path = "/"
        var secure = false
        var httpOnly = false
        var expiry: Long? = null
        var maxAge: Long? = null
        for (attribute in parts.drop(1)) {
            val i = attribute.indexOf('=')
            val key = (if (i < 0) attribute else attribute.substring(0, i)).trim().lowercase()
            val v = if (i < 0) "" else attribute.substring(i + 1).trim()
            when (key) {
                "domain" -> domain = v.lowercase().takeIf { it.isNotEmpty() }
                "path" -> path = v.ifEmpty { "/" }
                "secure" -> secure = true
                "httponly" -> httpOnly = true
                "expires" -> expiry = runCatching { ZonedDateTime.parse(v.replace('-', ' '), expiresFormat).toEpochSecond() }.getOrNull()
                    ?: runCatching { ZonedDateTime.parse(v, expiresFormat).toEpochSecond() }.getOrNull()
                "max-age" -> maxAge = v.toLongOrNull()
            }
        }
        maxAge?.let { expiry = nowMs / 1000 + it }
        // A Domain attribute always covers subdomains; without one the cookie is the host's alone.
        val cookieDomain = domain?.let { if (it.startsWith(".")) it else ".$it" } ?: host.lowercase()
        val finalDomain = if (name.startsWith("__Host-")) host.lowercase() else cookieDomain
        return Cookie(finalDomain, name, value, path, secure, expiry, httpOnly)
    }

    /**
     * The fallback without `getCookieInfo`: `CookieManager.getCookie` gives only "a=1; b=2" per
     * URL. They're written for the whole site (".youtube.com" / ".google.com"), except `__Host-`
     * cookies (the exact host), all secure, path "/", expiring in 400 days.
     */
    fun fromCookieHeader(header: String, host: String, nowMs: Long): List<Cookie> {
        val base = DOMAINS.firstOrNull { matches(host, it) } ?: return emptyList()
        val expiry = nowMs / 1000 + FALLBACK_LIFETIME_SECONDS
        return header.split(";").mapNotNull { pair ->
            val i = pair.indexOf('=')
            if (i <= 0) return@mapNotNull null
            val name = pair.substring(0, i).trim()
            val value = pair.substring(i + 1).trim()
            if (name.isEmpty()) return@mapNotNull null
            val domain = if (name.startsWith("__Host-")) host.lowercase() else ".$base"
            Cookie(domain, name, value, "/", true, expiry)
        }
    }

    /**
     * Cookies read from several URLs, one per (domain, name): the first URL's wins, so list
     * www before m.
     */
    fun deduplicate(cookies: List<Cookie>): List<Cookie> {
        val seen = HashSet<Pair<String, String>>()
        return cookies.filter { seen.add(it.domain.lowercase() to it.name) }
    }
}
