package dev.stow.android.standalone

import org.json.JSONArray
import org.json.JSONObject
import java.net.URLDecoder

/**
 * YouTube's /feed/channels data (a port of the Mac's `SubscriptionsParser`). Rather than a fixed
 * path, which YouTube reshuffles often, it collects every "channelRenderer" anywhere in the tree,
 * plus the first continuation token.
 */
object SubscriptionsParser {
    data class Page(val channels: List<ChannelInfo>, val continuation: String?)

    fun parse(json: String): Page {
        val walker = Walker()
        walker.visit(JSONObject(json))
        return Page(walker.channels, walker.continuation)
    }

    private class Walker {
        val channels = ArrayList<ChannelInfo>()
        var continuation: String? = null
        private val seen = HashSet<String>()

        fun visit(node: Any?) {
            when (node) {
                is JSONArray -> for (i in 0 until node.length()) visit(node.opt(i))
                is JSONObject -> for (key in node.keys().asSequence().sorted().toList()) {
                    val value = node.opt(key)
                    when (key) {
                        "channelRenderer" -> (value as? JSONObject)?.let(::channel)?.takeIf { seen.add(it.id) }?.let(channels::add)
                        "continuationItemRenderer", "nextContinuationData" ->
                            if (continuation == null) continuation = continuationToken(value)
                        else -> visit(value)
                    }
                }
            }
        }
    }

    private fun channel(renderer: JSONObject): ChannelInfo? {
        val id = renderer.optString("channelId").takeIf { it.startsWith("UC") } ?: return null
        return ChannelInfo(id, text(renderer.opt("title")) ?: id, handle(renderer), avatar(renderer))
    }

    /** In the browse endpoint's canonicalBaseUrl ("/@name", percent-encoded) or, in the current layout, subscriberCountText ("@name"). */
    private fun handle(renderer: JSONObject): String? {
        val base = renderer.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")?.optString("canonicalBaseUrl").orEmpty()
        if (base.startsWith("/@")) {
            val raw = base.drop(1)
            return runCatching { URLDecoder.decode(raw, "UTF-8") }.getOrDefault(raw)
        }
        val text = text(renderer.opt("subscriberCountText"))
        return text?.takeIf { it.startsWith("@") && ' ' !in it }
    }

    /** The widest thumbnail; YouTube serves protocol-relative "//yt3…" URLs. */
    private fun avatar(renderer: JSONObject): String? {
        val thumbnails = renderer.optJSONObject("thumbnail")?.optJSONArray("thumbnails") ?: return null
        val best = (0 until thumbnails.length()).mapNotNull { thumbnails.optJSONObject(it) }.maxByOrNull { it.optInt("width") }
        val raw = best?.optString("url")?.takeIf { it.isNotEmpty() } ?: return null
        return if (raw.startsWith("//")) "https:$raw" else raw
    }

    /** {"simpleText": "…"} or {"runs": [{"text": "…"}, …]}. */
    private fun text(value: Any?): String? {
        val o = value as? JSONObject ?: return null
        if (o.has("simpleText")) return o.optString("simpleText")
        val runs = o.optJSONArray("runs") ?: return null
        val parts = (0 until runs.length()).mapNotNull { runs.optJSONObject(it)?.optString("text") }
        return parts.takeIf { it.isNotEmpty() }?.joinToString("")
    }

    /** `continuationCommand.token` (current) or `continuation` (legacy nextContinuationData). */
    private fun continuationToken(value: Any?): String? {
        when (value) {
            is JSONObject -> {
                value.optJSONObject("continuationCommand")?.optString("token")?.takeIf { it.isNotEmpty() }?.let { return it }
                (value.opt("continuation") as? String)?.let { return it }
                for (key in value.keys().asSequence().sorted().toList()) continuationToken(value.opt(key))?.let { return it }
            }
            is JSONArray -> for (i in 0 until value.length()) continuationToken(value.opt(i))?.let { return it }
        }
        return null
    }
}
