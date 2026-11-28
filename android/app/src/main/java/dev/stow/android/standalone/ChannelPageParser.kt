package dev.stow.android.standalone

import java.net.URLDecoder

/** A channel as YouTube names it. */
data class ChannelInfo(val id: String, val title: String, val handle: String? = null, val avatarUrl: String? = null)

/** The few fields Stow needs from youtube.com HTML (a port of the Mac's `ChannelPageParser`). */
object ChannelPageParser {
    private val identifier = Regex("""<meta itemprop="identifier" content="(UC[A-Za-z0-9_-]{22})"""")
    private val externalId = Regex(""""externalId":"(UC[A-Za-z0-9_-]{22})"""")
    private val vanity = Regex(""""vanityChannelUrl":"https?:(?:\\?/){2}www\.youtube\.com(?:\\?/)(@[^"]+)"""")
    private val ownerChannel = Regex(""""channelId":"(UC[A-Za-z0-9_-]{22})"""")
    private val entity = Regex("""&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);""")

    /** Id, title, handle and avatar from a channel page; null when the page doesn't carry them (consent wall, layout change). */
    fun parse(html: String): ChannelInfo? {
        val id = identifier.find(html)?.groupValues?.get(1) ?: externalId.find(html)?.groupValues?.get(1) ?: return null
        val title = meta("og:title", html)?.takeIf { it.isNotEmpty() } ?: return null
        val handle = vanity.find(html)?.groupValues?.get(1)?.let { runCatching { URLDecoder.decode(it, "UTF-8") }.getOrDefault(it) }
        return ChannelInfo(id, title, handle, meta("og:image", html)?.takeIf { it.isNotEmpty() })
    }

    /** The uploader's channel from a watch page: the first "channelId" is in videoDetails, ahead of recommendations. */
    fun ownerChannelId(watchPage: String): String? = ownerChannel.find(watchPage)?.groupValues?.get(1)

    private fun meta(property: String, html: String): String? =
        Regex("""<meta property="${Regex.escape(property)}" content="([^"]*)"""").find(html)?.groupValues?.get(1)?.let(::decodeEntities)

    fun decodeEntities(text: String): String {
        if ('&' !in text) return text
        return entity.replace(text) { match ->
            when (val e = match.groupValues[1]) {
                "amp" -> "&"
                "lt" -> "<"
                "gt" -> ">"
                "quot" -> "\""
                "apos" -> "'"
                else -> {
                    val hex = e.startsWith("#x")
                    val code = e.drop(if (hex) 2 else 1).toIntOrNull(if (hex) 16 else 10)
                    code?.takeIf { Character.isValidCodePoint(it) }?.let { String(Character.toChars(it)) } ?: match.value
                }
            }
        }
    }
}
