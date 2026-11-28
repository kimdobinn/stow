package dev.stow.android.standalone

import org.json.JSONObject
import java.net.URI
import java.net.URLEncoder

/** What someone typed, classified without the network. */
sealed interface ChannelReference {
    data class Id(val id: String) : ChannelReference
    /** Without the "@". */
    data class Handle(val handle: String) : ChannelReference
    /** A legacy /c/ or /user/ URL, on www.youtube.com. */
    data class Url(val url: String) : ChannelReference
    /** A video: resolves to its uploader's channel. */
    data class VideoRef(val videoId: String) : ChannelReference
}

/** A channel that couldn't be added; the message is for the user. */
class ChannelInputException(message: String) : Exception(message)

/** Turns a URL, @handle or channel id into a channel (a port of the Mac's `ChannelResolver`). */
class ChannelResolver(private val web: WebClient, private val tool: YouTubeTool) {
    suspend fun resolve(input: String): ChannelInfo {
        val text = input.trim()
        val reference = parse(text) ?: throw invalid(text)
        return when (reference) {
            is ChannelReference.Id -> resolvePage(channelUrl(reference.id), text)
            is ChannelReference.Handle -> resolvePage("https://www.youtube.com/@" + URLEncoder.encode(reference.handle, "UTF-8"), text)
            is ChannelReference.Url -> resolvePage(reference.url, text)
            is ChannelReference.VideoRef -> resolvePage(channelUrl(owningChannelId(reference.videoId, text)), text)
        }
    }

    /** The channel page's fields; yt-dlp when the page can't be parsed. */
    private suspend fun resolvePage(url: String, input: String): ChannelInfo {
        val response = web.get(url)
        if (response.status == 404) throw notFound(input)
        if (response.isSlowDown) throw SlowDown("YouTube answered ${response.status}")
        if (response.status == 200) ChannelPageParser.parse(response.body)?.let { return it }
        val json = mapNotFound(input) { tool.run(listOf("-J", "--flat-playlist", "--playlist-items", "0", url), null).stdout }
        val o = runCatching { JSONObject(json) }.getOrNull() ?: throw notFound(input)
        val id = o.optString("channel_id").takeIf(::isChannelId) ?: throw notFound(input)
        return ChannelInfo(id, o.optString("channel").takeIf { it.isNotEmpty() && it != "null" } ?: id,
                           o.optString("uploader_id").takeIf { it.startsWith("@") }, YouTubeJson.avatar(o))
    }

    private suspend fun owningChannelId(videoId: String, input: String): String {
        val watch = "https://www.youtube.com/watch?v=$videoId"
        val response = web.get(watch)
        if (response.status == 200) ChannelPageParser.ownerChannelId(response.body)?.let { return it }
        val json = mapNotFound(input) { tool.run(listOf("-J", "--skip-download", "--no-playlist", watch), null).stdout }
        return runCatching { JSONObject(json).optString("channel_id") }.getOrNull()?.takeIf(::isChannelId) ?: throw notFound(input)
    }

    private suspend fun mapNotFound(input: String, body: suspend () -> String): String = try {
        body()
    } catch (e: ToolFailure) {
        if (e.kind == YouTubeFailure.Kind.UNAVAILABLE) throw notFound(input) else throw e
    }

    companion object {
        private val channelId = Regex("UC[A-Za-z0-9_-]{22}")
        private val videoId = Regex("[A-Za-z0-9_-]{11}")

        fun isChannelId(text: String) = channelId.matches(text)
        fun channelUrl(id: String) = "https://www.youtube.com/channel/$id"
        fun invalid(input: String) = ChannelInputException("Not a channel URL, @handle or channel ID: $input")
        fun notFound(input: String) = ChannelInputException("Channel not found: $input")
        fun alreadyAdded(title: String) = ChannelInputException("$title is already added.")

        /** Null when the input can't be a channel reference. */
        fun parse(input: String): ChannelReference? {
            val text = input.trim()
            if (isChannelId(text)) return ChannelReference.Id(text)
            if (text.startsWith("@")) return handle(text.drop(1))?.let(ChannelReference::Handle)
            val lowered = text.lowercase()
            if ("youtube.com" in lowered || "youtu.be" in lowered) return parseUrl(text)
            return handle(text)?.let(ChannelReference::Handle)
        }

        private fun parseUrl(text: String): ChannelReference? {
            val uri = runCatching { URI(if ("://" in text) text else "https://$text") }.getOrNull() ?: return null
            val host = uri.host?.lowercase() ?: return null
            val parts = uri.path.orEmpty().split("/").filter { it.isNotEmpty() }
            if (host == "youtu.be") return parts.firstOrNull()?.let(::video)?.let(ChannelReference::VideoRef)
            if (host != "youtube.com" && !host.endsWith(".youtube.com")) return null
            val first = parts.firstOrNull() ?: return null
            if (first.startsWith("@")) return handle(first.drop(1))?.let(ChannelReference::Handle)
            val second = parts.getOrNull(1)
            return when (first) {
                "channel" -> second?.takeIf(::isChannelId)?.let(ChannelReference::Id)
                "c", "user" -> second?.let { ChannelReference.Url("https://www.youtube.com/$first/" + URLEncoder.encode(it, "UTF-8").replace("+", "%20")) }
                "watch" -> query(uri, "v")?.let(::video)?.let(ChannelReference::VideoRef)
                "shorts", "live", "embed", "v" -> second?.let(::video)?.let(ChannelReference::VideoRef)
                else -> null
            }
        }

        private fun query(uri: URI, name: String): String? = uri.rawQuery?.split("&")?.firstNotNullOfOrNull { pair ->
            val i = pair.indexOf('=')
            if (i > 0 && pair.substring(0, i) == name) java.net.URLDecoder.decode(pair.substring(i + 1), "UTF-8") else null
        }

        /** Handles allow letters in any script, digits, ".", "_", "-" and "·". */
        private fun handle(text: String): String? =
            text.takeIf { it.length in 1..100 && it.all { c -> c.isLetter() || c.isDigit() || c in "._-·" } }

        private fun video(text: String): String? = text.takeIf(videoId::matches)
    }
}

/** Bits of yt-dlp's JSON several listings share. */
object YouTubeJson {
    /** The channel's picture on a channel listing. */
    fun avatar(o: JSONObject): String? {
        val thumbnails = o.optJSONArray("thumbnails") ?: return null
        return (0 until thumbnails.length()).mapNotNull { thumbnails.optJSONObject(it) }
            .firstOrNull { it.optString("id") == "avatar_uncropped" }?.optString("url")?.takeIf { it.isNotEmpty() }
    }

    fun string(o: JSONObject, key: String): String? = o.optString(key).takeIf { o.has(key) && !o.isNull(key) && it.isNotEmpty() }
    fun double(o: JSONObject, key: String): Double? = if (o.has(key) && !o.isNull(key)) o.optDouble(key).takeIf { !it.isNaN() } else null
}
