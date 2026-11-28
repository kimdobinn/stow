package dev.stow.android.standalone

import dev.stow.android.account.Cookie
import dev.stow.android.account.NetscapeCookies
import org.json.JSONObject
import java.io.IOException
import java.security.MessageDigest

/**
 * The signed-in account's subscriptions, over plain HTTP (a port of the Mac's
 * `SubscriptionsFetcher`, which drives a hidden web view): /feed/channels with the account's
 * cookies for the first page, then InnerTube `browse` continuations the way YouTube's web client
 * asks for them (SAPISIDHASH headers).
 */
class SubscriptionsImport(private val web: WebClient) {
    /** Throws [SignedOutByYouTube] when YouTube sends the request to its sign-in page. */
    suspend fun fetch(cookies: List<Cookie>, nowMs: Long = System.currentTimeMillis()): List<ChannelInfo> {
        val cookieHeader = cookieHeader(cookies)
        val response = web.get(FEED_URL, mapOf("Cookie" to cookieHeader))
        if ("accounts.google.com" in response.finalUrl) throw SignedOutByYouTube()
        if (response.isSlowDown) throw SlowDown("YouTube answered ${response.status}")
        if (response.status != 200) throw IOException("YouTube answered ${response.status} for your subscriptions")
        val initial = initialData(response.body) ?: throw SignedOutByYouTube()
        val config = config(response.body)
        var page = SubscriptionsParser.parse(initial)
        val channels = ArrayList(page.channels)
        val seen = channels.mapTo(HashSet()) { it.id }
        val used = HashSet<String>()
        var pages = 1
        while (true) {
            val token = page.continuation ?: break
            if (!used.add(token) || channels.size >= MAX_CHANNELS || pages >= MAX_PAGES) break
            page = try {
                continuation(token, config, cookies, cookieHeader, nowMs / 1000)
            } catch (e: Exception) {
                // The pages read so far are still useful (channels can also be added by URL).
                break
            }
            pages++
            channels += page.channels.filter { seen.add(it.id) }
        }
        return channels.take(MAX_CHANNELS)
    }

    private suspend fun continuation(token: String, config: JSONObject, cookies: List<Cookie>, cookieHeader: String, ts: Long): SubscriptionsParser.Page {
        val body = JSONObject().put("context", config.optJSONObject("INNERTUBE_CONTEXT") ?: JSONObject()).put("continuation", token)
        val headers = HashMap(continuationHeaders(config, cookies, ts))
        headers["Cookie"] = cookieHeader
        val response = web.post(BROWSE_URL, body.toString(), headers)
        if (response.status !in 200..299) throw IOException("browse HTTP ${response.status}")
        return SubscriptionsParser.parse(response.body)
    }

    companion object {
        const val FEED_URL = "https://www.youtube.com/feed/channels"
        const val BROWSE_URL = "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false"
        const val ORIGIN = "https://www.youtube.com"
        const val MAX_CHANNELS = 500
        const val MAX_PAGES = 50

        /** Every youtube.com cookie as `name=value; …`, plus SOCS=CAI (skips the EU consent page) unless there's one. */
        fun cookieHeader(cookies: List<Cookie>): String {
            val header = NetscapeCookies.header(cookies, "www.youtube.com")
            return if (cookies.any { it.name == "SOCS" && NetscapeCookies.matches(it.domain, "youtube.com") }) header
                   else listOf(header, "SOCS=CAI").filter { it.isNotEmpty() }.joinToString("; ")
        }

        /** `<ts>_<sha1("<ts> <sid> https://www.youtube.com")>`. */
        fun sapisidHash(ts: Long, sid: String, origin: String = ORIGIN): String {
            val digest = MessageDigest.getInstance("SHA-1").digest("$ts $sid $origin".toByteArray(Charsets.UTF_8))
            return "${ts}_" + digest.joinToString("") { "%02x".format(it) }
        }

        /** The Authorization header YouTube's web client sends, or null without a SAPISID cookie. */
        fun authorization(cookies: List<Cookie>, ts: Long): String? {
            fun value(name: String) = cookies.firstOrNull { it.name == name && NetscapeCookies.matches(it.domain, "youtube.com") }?.value
                ?: cookies.firstOrNull { it.name == name }?.value
            val schemes = listOf(
                "SAPISIDHASH" to (value("SAPISID") ?: value("__Secure-3PAPISID")),
                "SAPISID1PHASH" to value("__Secure-1PAPISID"),
                "SAPISID3PHASH" to value("__Secure-3PAPISID"),
            )
            return schemes.mapNotNull { (scheme, sid) -> sid?.let { "$scheme ${sapisidHash(ts, it)}" } }.takeIf { it.isNotEmpty() }?.joinToString(" ")
        }

        /** The continuation request's headers, as in the Mac's script. */
        fun continuationHeaders(config: JSONObject, cookies: List<Cookie>, ts: Long): Map<String, String> {
            val headers = linkedMapOf(
                "Content-Type" to "application/json",
                "X-Origin" to ORIGIN,
                "Origin" to ORIGIN,
                "X-Goog-AuthUser" to (config.opt("SESSION_INDEX")?.toString()?.takeIf { it != "null" } ?: "0"),
                "X-Youtube-Client-Name" to (config.opt("INNERTUBE_CONTEXT_CLIENT_NAME")?.toString()?.takeIf { it != "null" } ?: "1"),
                "X-Youtube-Client-Version" to config.optString("INNERTUBE_CLIENT_VERSION"),
            )
            authorization(cookies, ts)?.let { headers["Authorization"] = it }
            config.optString("DELEGATED_SESSION_ID").takeIf { it.isNotEmpty() && it != "null" }?.let { headers["X-Goog-PageId"] = it }
            return headers
        }

        /** `var ytInitialData = {…};` from the page. */
        fun initialData(html: String): String? {
            val marker = Regex("""(?:var\s+ytInitialData|window\[["']ytInitialData["']\])\s*=\s*""").find(html) ?: return null
            return jsonObject(html, marker.range.last + 1)
        }

        /** Every `ytcfg.set({…})` on the page, merged. */
        fun config(html: String): JSONObject {
            val merged = JSONObject()
            for (match in Regex("""ytcfg\.set\(\s*""").findAll(html)) {
                val text = jsonObject(html, match.range.last + 1) ?: continue
                val o = runCatching { JSONObject(text) }.getOrNull() ?: continue
                for (key in o.keys()) merged.put(key, o.opt(key))
            }
            return merged
        }

        /** The JSON object starting at `start` (it must be "{"), by matching braces outside strings. */
        fun jsonObject(text: String, start: Int): String? {
            if (start >= text.length || text[start] != '{') return null
            var depth = 0
            var inString = false
            var escaped = false
            for (i in start until text.length) {
                val c = text[i]
                if (inString) {
                    when {
                        escaped -> escaped = false
                        c == '\\' -> escaped = true
                        c == '"' -> inString = false
                    }
                    continue
                }
                when (c) {
                    '"' -> inString = true
                    '{' -> depth++
                    '}' -> if (--depth == 0) return text.substring(start, i + 1)
                }
            }
            return null
        }
    }
}
