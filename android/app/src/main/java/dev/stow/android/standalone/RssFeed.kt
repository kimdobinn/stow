package dev.stow.android.standalone

import dev.stow.android.data.Video
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.IOException
import java.io.StringReader
import java.net.URLEncoder
import java.time.OffsetDateTime
import java.util.Date
import javax.xml.parsers.SAXParserFactory

/**
 * YouTube's Atom feeds (a port of the Mac's `RSSFeedParser` and `RSSFeedFetcher`): no yt-dlp,
 * one small request per channel. Parsed with SAX (javax.xml), which Android and the JVM tests
 * both have.
 */
object RssFeed {
    const val BASE = "https://www.youtube.com/feeds/videos.xml"

    fun playlistUrl(playlistId: String) = "$BASE?playlist_id=${URLEncoder.encode(playlistId, "UTF-8")}"
    fun channelUrl(channelId: String) = "$BASE?channel_id=${URLEncoder.encode(channelId, "UTF-8")}"

    /** The playlist ids of a channel's lists: long-form uploads (no Shorts, no streams), past streams, members-only. */
    object Playlists {
        private fun suffix(channelId: String) = channelId.removePrefix("UC")
        fun uploads(channelId: String) = "UULF" + suffix(channelId)
        fun liveStreams(channelId: String) = "UULV" + suffix(channelId)
        fun members(channelId: String) = "UUMF" + suffix(channelId)
        fun memberStreams(channelId: String) = "UUMV" + suffix(channelId)
    }

    /** A feed that doesn't exist (404). */
    class NotFound(id: String) : Exception("Feed not found: $id")

    /** Thrown for anything not an Atom feed. Videos get isMembersOnly = false and no live status (RSS can't tell). */
    fun parse(xml: String): List<Video> {
        val handler = Handler()
        val factory = SAXParserFactory.newInstance().apply {
            isNamespaceAware = true
            runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
            runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
        }
        try {
            factory.newSAXParser().parse(InputSource(StringReader(xml)), handler)
        } catch (e: Exception) {
            throw IOException("RSS feed: ${e.message}", e)
        }
        if (!handler.sawFeed) throw IOException("RSS feed: not an Atom feed")
        return handler.videos
    }

    /** One playlist's feed. 404 throws [NotFound]; 429 and 5xx throw [SlowDown]; others IOException. */
    suspend fun fetch(web: WebClient, url: String): List<Video> {
        val response = web.get(url)
        return when {
            response.status == 200 -> parse(response.body)
            response.status == 404 -> throw NotFound(url.substringAfter("="))
            response.isSlowDown -> throw SlowDown("YouTube answered ${response.status} for its RSS feed", response.status)
            else -> throw IOException("RSS feed returned HTTP ${response.status}")
        }
    }

    /**
     * A channel's long-form uploads. When the UULF feed is missing, the channel-wide feed tells
     * "no long-form videos" (empty) apart from "no such channel" ([NotFound]).
     */
    suspend fun uploads(web: WebClient, channelId: String): List<Video> = try {
        fetch(web, playlistUrl(Playlists.uploads(channelId)))
    } catch (e: NotFound) {
        fetch(web, channelUrl(channelId))
        emptyList()
    }

    private class Handler : DefaultHandler() {
        val videos = ArrayList<Video>()
        var sawFeed = false
        private val path = ArrayList<String>()
        private val text = StringBuilder()
        private var feedAuthor: String? = null
        private var entry: HashMap<String, String>? = null
        private var thumbnail: String? = null

        private fun name(localName: String?, qName: String?) = localName?.takeIf { it.isNotEmpty() } ?: qName?.substringAfter(':').orEmpty()

        override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes) {
            val name = name(localName, qName)
            if (path.isEmpty() && name == "feed") sawFeed = true
            path.add(name)
            text.setLength(0)
            when (name) {
                "entry" -> { entry = HashMap(); thumbnail = null }
                "thumbnail" -> if (entry != null) thumbnail = attributes.getValue("url")
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            text.append(ch, start, length)
        }

        override fun endElement(uri: String?, localName: String?, qName: String?) {
            val name = name(localName, qName)
            val value = text.toString().trim()
            text.setLength(0)
            val parent = path.getOrNull(path.size - 2)
            val depth = path.size
            path.removeAt(path.size - 1)
            if (name == "name" && parent == "author" && depth == 3) {
                feedAuthor = value // feed > author > name
                return
            }
            val current = entry ?: return
            when {
                parent == "entry" && name in setOf("videoId", "channelId", "title", "published") -> current[name] = value
                parent == "author" && name == "name" -> current["author"] = value
                name == "entry" -> {
                    makeVideo(current)?.let(videos::add)
                    entry = null
                }
            }
        }

        private fun makeVideo(e: Map<String, String>): Video? {
            val id = e["videoId"]?.takeIf { it.isNotEmpty() } ?: return null
            val channelId = e["channelId"] ?: return null
            return Video(
                id = id, channelId = channelId, channelTitle = e["author"] ?: feedAuthor ?: channelId,
                title = e["title"] ?: id,
                publishedAt = e["published"]?.let { runCatching { Date.from(OffsetDateTime.parse(it).toInstant()) }.getOrNull() },
                thumbnailUrl = thumbnail, isMembersOnly = false, liveStatus = null,
            )
        }
    }
}
