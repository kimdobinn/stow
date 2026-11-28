package dev.stow.android.standalone

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** An HTTP answer: status, body and where redirects ended up. */
data class WebResponse(val status: Int, val body: String, val finalUrl: String) {
    val isSlowDown: Boolean get() = status == 429 || status in 500..599
}

/** youtube.com over HTTP. Throws IOException only when the request didn't get an answer. */
interface WebClient {
    suspend fun get(url: String, headers: Map<String, String> = emptyMap()): WebResponse
    suspend fun post(url: String, body: String, headers: Map<String, String> = emptyMap()): WebResponse
}

/**
 * Cookie-less requests to youtube.com, shaped like the Mac's `YouTubeHTTP` (a desktop Safari user
 * agent gets the full page the parsers expect; SOCS skips the EU consent page). Nothing is stored:
 * there's no cookie jar, and callers that need the account's cookies pass a Cookie header.
 */
class YouTubeWeb(private val timeoutMs: Int = TIMEOUT_MS) : WebClient {
    override suspend fun get(url: String, headers: Map<String, String>): WebResponse = request("GET", url, null, headers)
    override suspend fun post(url: String, body: String, headers: Map<String, String>): WebResponse = request("POST", url, body, headers)

    private suspend fun request(method: String, url: String, body: String?, headers: Map<String, String>): WebResponse = withContext(Dispatchers.IO) {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.instanceFollowRedirects = true
            connection.useCaches = false
            (DEFAULT_HEADERS + headers).forEach { (k, v) -> connection.setRequestProperty(k, v) }
            if (body != null) {
                connection.doOutput = true
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) }.orEmpty()
            WebResponse(status, text, connection.url.toString())
        } catch (e: IOException) {
            throw e
        } catch (e: Exception) {
            throw IOException(e.message ?: e.javaClass.simpleName, e)
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        const val TIMEOUT_MS = 30_000
        const val USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        val DEFAULT_HEADERS = mapOf(
            "User-Agent" to USER_AGENT,
            "Accept-Language" to "en-US,en;q=0.9",
            "Cookie" to "SOCS=CAI",
        )
    }
}
