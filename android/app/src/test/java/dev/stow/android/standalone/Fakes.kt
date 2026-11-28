package dev.stow.android.standalone

import java.io.IOException

/** Test resources (src/test/resources). */
fun fixture(name: String): String = requireNotNull(object {}.javaClass.getResource("/$name")) { "no fixture $name" }.readText()

val CHANNEL_A = "UC" + "a".repeat(22)
val CHANNEL_B = "UC" + "b".repeat(22)

/**
 * youtube.com for tests: answers by URL. Anything not set is a 404. Every request is recorded,
 * and nothing in the tests may reach Firebase (a Firebase host fails the test).
 */
class FakeWeb(private val answers: MutableMap<String, WebResponse> = mutableMapOf()) : WebClient {
    val requests = mutableListOf<String>()
    var failAll: Boolean = false

    fun set(url: String, body: String, status: Int = 200, finalUrl: String = url) {
        answers[url] = WebResponse(status, body, finalUrl)
    }

    private fun answer(url: String): WebResponse {
        check(FIREBASE_HOSTS.none { it in url }) { "Standalone mode reached Firebase: $url" }
        requests += url
        if (failAll) throw IOException("offline")
        return answers[url] ?: WebResponse(404, "", url)
    }

    override suspend fun get(url: String, headers: Map<String, String>) = answer(url)
    override suspend fun post(url: String, body: String, headers: Map<String, String>) = answer(url)

    companion object {
        val FIREBASE_HOSTS = listOf("firestore.googleapis.com", "identitytoolkit.googleapis.com", "securetoken.googleapis.com", "fcm.googleapis.com")
    }
}

/** yt-dlp for tests: each run is answered by `handler` (args, cookies) and recorded. */
class FakeTool(var handler: (List<String>, String?) -> ToolOutput = { _, _ -> ToolOutput("{}") }) : YouTubeTool {
    val runs = mutableListOf<Pair<List<String>, String?>>()
    override suspend fun run(args: List<String>, cookies: String?, timeoutMs: Long): ToolOutput {
        runs += args to cookies
        return handler(args, cookies)
    }
    fun ran(fragment: String) = runs.any { (args, _) -> args.any { fragment in it } }
}

class FakeHost : Standalone.Host {
    val watched = LinkedHashSet<String>()
    val downloaded = HashSet<String>()
    var signedOutNotices = 0
    var webDataCleared = 0
    override fun watchedHere(): Set<String> = watched
    override fun addWatchedHere(ids: Collection<String>) { watched += ids }
    override fun downloadedIds(): Set<String> = downloaded
    override fun onSignedOutByYouTube() { signedOutNotices++ }
    override fun clearWebData() { webDataCleared++ }
}
