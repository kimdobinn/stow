package dev.stow.android.sync

import android.content.Context
import android.os.Environment
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import dev.stow.android.data.Prefs
import dev.stow.android.data.Video
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/** yt-dlp (with its own Python, ffmpeg and QuickJS) from youtubedl-android. */
object YtDlp {
    private val mutex = Mutex()
    @Volatile private var ready = false
    private const val UPDATE_INTERVAL_MS = 24 * 60 * 60 * 1000L

    /** Unpacks Python and ffmpeg the first time (a few seconds). */
    suspend fun ensureReady(context: Context) = mutex.withLock {
        if (ready) return@withLock
        withContext(Dispatchers.IO) {
            YoutubeDL.getInstance().init(context.applicationContext)
            FFmpeg.getInstance().init(context.applicationContext)
        }
        ready = true
    }

    /** YouTube changes often; keep yt-dlp at the newest stable release (checked daily). */
    suspend fun updateIfDue(context: Context, prefs: Prefs, force: Boolean = false): String? {
        if (!force && System.currentTimeMillis() - prefs.lastYtDlpUpdate < UPDATE_INTERVAL_MS) return null
        ensureReady(context)
        return withContext(Dispatchers.IO) {
            runCatching {
                val status = YoutubeDL.getInstance().updateYoutubeDL(context.applicationContext, YoutubeDL.UpdateChannel.STABLE)
                prefs.lastYtDlpUpdate = System.currentTimeMillis()
                status?.name
            }.onFailure { Log.w("Stow", "yt-dlp update failed", it) }.getOrNull()
        }
    }

    fun version(context: Context): String? = runCatching { YoutubeDL.getInstance().version(context.applicationContext) }.getOrNull()

    fun downloadDir(context: Context): File =
        File(context.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: context.filesDir, "stow").apply { mkdirs() }

    fun deleteFiles(context: Context, id: String) {
        downloadDir(context).listFiles { file -> file.name.startsWith("$id.") }?.forEach { it.delete() }
    }

    /**
     * Downloads the best H.264 video up to 1080p (preferring 60 fps) with AAC audio, merged into
     * an MP4. `cookies` (members-only videos) is a Netscape cookies.txt. Returns the file.
     */
    suspend fun download(context: Context, video: Video, cookies: File?, onProgress: (Int) -> Unit): File =
        withContext(Dispatchers.IO) {
            ensureReady(context)
            val dir = downloadDir(context)
            val request = YoutubeDLRequest(video.watchUrl).apply {
                addOption("-o", File(dir, "%(id)s.%(ext)s").absolutePath)
                // H.264 + AAC: hardware-decoded on every phone (AV1 isn't everywhere).
                addOption("-S", "res:1080,fps,vcodec:h264,acodec:m4a")
                addOption("-f", "bv*+ba/b")
                addOption("--merge-output-format", "mp4")
                addOption("--no-playlist")
                addOption("--no-mtime")
                addOption("--newline")
                if (cookies != null) addOption("--cookies", cookies.absolutePath)
            }
            var last = -1
            val response = YoutubeDL.getInstance().execute(request, video.id) { progress, _, _ ->
                val percent = progress.toInt().coerceIn(0, 100)
                if (percent != last) {
                    last = percent
                    onProgress(percent)
                }
            }
            if (response.exitCode != 0) error(summary(response.err))
            dir.listFiles { file ->
                file.name.startsWith("${video.id}.") && file.extension in setOf("mp4", "mkv", "webm") && !file.name.contains(".f")
            }?.maxByOrNull { it.length() } ?: error("yt-dlp finished but no file was found")
        }

    /** Where to stream a video from: video URL, separate audio URL (HD), and the HTTP headers. */
    data class Stream(val videoUrl: String, val audioUrl: String?, val headers: Map<String, String>)

    /** Resolves the same format a download would pick, without downloading (a few seconds). */
    suspend fun stream(context: Context, video: Video, cookies: File?): Stream = withContext(Dispatchers.IO) {
        ensureReady(context)
        val request = YoutubeDLRequest(video.watchUrl).apply {
            addOption("-j")
            addOption("-S", "res:1080,fps,vcodec:h264,acodec:m4a")
            addOption("-f", "bv*+ba/b")
            addOption("--no-playlist")
            if (cookies != null) addOption("--cookies", cookies.absolutePath)
        }
        val response = YoutubeDL.getInstance().execute(request, "stream-${video.id}")
        if (response.exitCode != 0) error(summary(response.err))
        val info = org.json.JSONObject(response.out.lineSequence().first { it.trimStart().startsWith("{") })
        fun headers(o: org.json.JSONObject) = o.optJSONObject("http_headers")?.let { h ->
            h.keys().asSequence().associateWith { h.getString(it) }
        }.orEmpty()
        val formats = info.optJSONArray("requested_formats")
        if (formats != null && formats.length() >= 2) {
            val parts = (0 until formats.length()).map { formats.getJSONObject(it) }
            val videoPart = parts.firstOrNull { it.optString("vcodec") != "none" } ?: parts[0]
            val audioPart = parts.firstOrNull { it.optString("vcodec") == "none" } ?: parts[1]
            Stream(videoPart.getString("url"), audioPart.getString("url"), headers(videoPart))
        } else {
            Stream(info.getString("url"), null, headers(info))
        }
    }

    /** What a download would take, in bytes (yt-dlp's figure for the format it would pick); null when it doesn't say. */
    suspend fun downloadSize(context: Context, video: Video, cookies: File?): Long? = withContext(Dispatchers.IO) {
        ensureReady(context)
        val request = YoutubeDLRequest(video.watchUrl).apply {
            addOption("-j")
            addOption("-S", "res:1080,fps,vcodec:h264,acodec:m4a")
            addOption("-f", "bv*+ba/b")
            addOption("--no-playlist")
            if (cookies != null) addOption("--cookies", cookies.absolutePath)
        }
        val response = YoutubeDL.getInstance().execute(request, "size-${video.id}")
        if (response.exitCode != 0) return@withContext null
        val info = org.json.JSONObject(response.out.lineSequence().first { it.trimStart().startsWith("{") })
        fun size(o: org.json.JSONObject) = o.optLong("filesize").takeIf { it > 0 } ?: o.optLong("filesize_approx").takeIf { it > 0 }
        val formats = info.optJSONArray("requested_formats")
        if (formats != null && formats.length() > 0) {
            val sizes = (0 until formats.length()).map { size(formats.getJSONObject(it)) }
            if (sizes.any { it == null }) null else sizes.sumOf { it!! }
        } else size(info)
    }

    fun cancel(id: String) {
        runCatching { YoutubeDL.getInstance().destroyProcessById(id) }
    }

    /** yt-dlp's ERROR lines, short enough for a status. */
    fun summary(stderr: String?): String {
        val lines = stderr.orEmpty().lines().map { it.trim() }.filter { it.isNotEmpty() }
        val errors = lines.filter { it.startsWith("ERROR:") }
        return (errors.ifEmpty { lines.takeLast(2) }).joinToString("\n").take(300).ifEmpty { "yt-dlp failed" }
    }
}
