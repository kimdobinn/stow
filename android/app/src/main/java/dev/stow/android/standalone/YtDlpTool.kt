package dev.stow.android.standalone

import android.content.Context
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import dev.stow.android.sync.YtDlp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

/** The real [YouTubeTool]: youtubedl-android's yt-dlp, at most two runs at a time. */
class YtDlpTool(private val context: Context, private val prefs: dev.stow.android.data.Prefs) : YouTubeTool {
    private val permits = Semaphore(MAX_RUNS)
    private val ids = AtomicLong()

    override suspend fun run(args: List<String>, cookies: String?, timeoutMs: Long): ToolOutput {
        // Not while holding a permit: the other runs wait for the update instead of racing it.
        YtDlp.updateBeforeUse(context, prefs)
        return permits.withPermit { runNow(args, cookies, timeoutMs) }
    }

    private suspend fun runNow(args: List<String>, cookies: String?, timeoutMs: Long): ToolOutput {
        YtDlp.ensureReady(context)
        val id = "standalone-${ids.incrementAndGet()}"
        val file = cookies?.let { writeCookies(context, it) }
        try {
            val request = YoutubeDLRequest(emptyList<String>()).apply {
                addCommands(listOf("--ignore-config", "--no-progress") +
                            (if (file != null) listOf("--cookies", file.absolutePath) else emptyList()) + args)
            }
            // yt-dlp blocks its thread: past the timeout, stop its process (execute then throws CanceledException).
            var timedOut = false
            val response = coroutineScope {
                val watchdog = launch {
                    delay(timeoutMs)
                    timedOut = true
                    YtDlp.cancel(id)
                }
                try {
                    withContext(Dispatchers.IO) {
                        try {
                            YoutubeDL.getInstance().execute(request, id)
                        } catch (e: YoutubeDL.CanceledException) {
                            throw IOException(if (timedOut) "yt-dlp timed out" else "yt-dlp was stopped")
                        } catch (e: YoutubeDLException) {
                            val text = e.message.orEmpty()
                            if (YouTubeFailure.isSlowDown(text)) throw SlowDown(YtDlp.summary(text))
                            throw ToolFailure(YtDlp.summary(text))
                        }
                    }
                } finally {
                    watchdog.cancel()
                }
            }
            return ToolOutput(response.out.orEmpty(), YouTubeFailure.cookiesRejected(response.err))
        } finally {
            file?.delete()
        }
    }

    companion object {
        const val MAX_RUNS = 2

        /** cookies.txt for one yt-dlp run: the cache folder, readable by the app only. The caller deletes it. */
        fun writeCookies(context: Context, text: String): File {
            val file = File(context.cacheDir, "cookies-${java.util.UUID.randomUUID()}.txt")
            file.createNewFile()
            file.setReadable(false, false); file.setReadable(true, true)
            file.setWritable(false, false); file.setWritable(true, true)
            file.writeText(text)
            return file
        }
    }
}
