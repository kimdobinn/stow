package dev.stow.android.update

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.provider.Settings
import android.util.Log
import dev.stow.android.BuildConfig
import dev.stow.android.data.Prefs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.UnknownHostException
import kotlin.coroutines.coroutineContext

/**
 * Updates the app from its GitHub releases (the same ones Obtainium reads): asks GitHub for the
 * latest release at most once a day, and on Update downloads the APK and hands it to Android's
 * package installer, which asks you to confirm.
 */
class Updater(private val context: Context, private val prefs: Prefs) {
    /** What the last check found. */
    sealed interface Check {
        /** Never checked (and nothing known). */
        data object Unknown : Check
        data object Checking : Check
        data object UpToDate : Check
        data class Available(val release: Release) : Check
        data class Failed(val message: String) : Check
    }

    /** Where an update is, once you tap Update. */
    sealed interface Install {
        data object Idle : Install
        /** Waiting for "Allow from this source" in Android's settings. */
        data class NeedsPermission(val release: Release) : Install
        data class Downloading(val release: Release, val bytes: Long) : Install
        /** Handed to Android; it shows its own confirm screen (and stops this app to update it). */
        data class Installing(val release: Release) : Install
        /** Android's confirm screen, for MainActivity to show. */
        data class Confirm(val release: Release, val intent: Intent) : Install
        data class Failed(val release: Release, val message: String) : Install
    }

    /** The installed version (from the package, so it's right right after an update). */
    val currentVersion: String =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: BuildConfig.VERSION_NAME

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val checking = Mutex()
    private var job: Job? = null
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var sessionId: Int? = null

    private val _check = MutableStateFlow(initialCheck())
    val check: StateFlow<Check> = _check.asStateFlow()

    private val _install = MutableStateFlow<Install>(Install.Idle)
    val install: StateFlow<Install> = _install.asStateFlow()

    /** The newer release the last successful check found. */
    val available: Release? get() = Release.fromJson(prefs.availableUpdate)?.takeIf { Versions.isNewer(it.version, currentVersion) }

    private fun initialCheck(): Check {
        val known = available
        if (known == null) {
            // Updated (or never found one): the old download has no use.
            prefs.availableUpdate = null
            File(context.cacheDir, DIR).deleteRecursively()
        }
        return when {
            known != null -> Check.Available(known)
            prefs.lastUpdateCheck > 0 -> Check.UpToDate
            else -> Check.Unknown
        }
    }

    /** Checks if the last check was a day ago or more (app start, the hourly sync). */
    suspend fun checkIfDue() {
        if (System.currentTimeMillis() - prefs.lastUpdateCheck < CHECK_INTERVAL_MS) return
        checkNow()
    }

    fun checkIfDueInBackground() { scope.launch { checkIfDue() } }

    /** The Settings row's "check now". */
    fun checkInBackground() { scope.launch { checkNow() } }

    suspend fun checkNow() {
        if (checking.isLocked) return
        checking.withLock {
            val before = _check.value
            _check.value = Check.Checking
            try {
                val release = fetchLatest()
                prefs.lastUpdateCheck = System.currentTimeMillis()
                if (release != null && Versions.isNewer(release.version, currentVersion)) {
                    prefs.availableUpdate = release.toJson()
                    _check.value = Check.Available(release)
                } else {
                    prefs.availableUpdate = null
                    _check.value = Check.UpToDate
                }
            } catch (e: CancellationException) {
                _check.value = before
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Update check failed", e)
                // A known update stays known when a later check can't get through.
                _check.value = available?.let { Check.Available(it) } ?: Check.Failed(describe(e))
            }
        }
    }

    /** The latest phone release on GitHub, or null if there's none. */
    private suspend fun fetchLatest(): Release? = withContext(Dispatchers.IO) {
        val connection = open(feedUrl).apply {
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
        }
        try {
            when (val code = connection.responseCode) {
                200 -> Release.parse(connection.inputStream.bufferedReader().use { it.readText() })
                404 -> null // No release yet.
                403, 429 -> throw IOException("GitHub is limiting checks for now (it lifts within an hour).")
                else -> throw IOException("GitHub answered with error $code.")
            }
        } finally {
            connection.disconnect()
        }
    }

    /** GitHub's latest non-pre-release; debug builds can point it elsewhere with files/update-feed. */
    private val feedUrl: String
        get() {
            if (BuildConfig.DEBUG) {
                File(context.filesDir, "update-feed").takeIf { it.exists() }?.readText()?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
            }
            return FEED_URL
        }

    // Installing

    val canInstall: Boolean get() = context.packageManager.canRequestPackageInstalls()

    /** Android's "Install unknown apps" page for this app. */
    fun allowInstallsIntent() = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))

    /** Update: download, check and install [release] (or first ask for "allow from this source"). */
    fun update(release: Release) {
        if (job?.isActive == true) return
        if (!canInstall) {
            _install.value = Install.NeedsPermission(release)
            return
        }
        _install.value = Install.Downloading(release, 0)
        job = scope.launch {
            try {
                val apk = download(release)
                // Not to be reused on Try again.
                runCatching { verify(apk, release) }.onFailure { apk.delete(); throw it }
                install(apk, release)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Update to ${release.version} failed", e)
                sessionId?.let { abandon(it) }
                if (coroutineContext.isActiveJob()) _install.value = Install.Failed(release, describe(e))
            }
        }
    }

    /** Back from Android's settings: carry on if installs are now allowed. */
    fun onResume() {
        val state = _install.value
        if (state is Install.NeedsPermission && canInstall) update(state.release)
    }

    /** Stops a download (or the install before it's handed to Android). */
    fun cancel() {
        job?.cancel()
        connection?.disconnect()
        sessionId?.let { abandon(it) }
        _install.value = Install.Idle
    }

    /** Closes a finished, failed or waiting update. */
    fun dismiss() {
        if (_install.value !is Install.Downloading) _install.value = Install.Idle
    }

    /** MainActivity started Android's confirm screen. */
    fun confirmShown(state: Install.Confirm) {
        _install.compareAndSet(state, Install.Installing(state.release))
    }

    private suspend fun download(release: Release): File {
        val dir = File(context.cacheDir, DIR)
        val file = File(dir, "Stow-${release.version}.apk")
        // Already here (you said Cancel on Android's screen, or it failed after the download).
        if (file.length() == release.apkSize) return file
        dir.deleteRecursively()
        dir.mkdirs()
        val connection = open(release.apkUrl, readTimeoutMs = 60_000).apply { setRequestProperty("Accept", "application/octet-stream") }
        this.connection = connection
        try {
            val code = connection.responseCode
            if (code !in 200..299) throw IOException("The download failed (error $code).")
            var bytes = 0L
            var shown = 0L
            connection.inputStream.use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        bytes += n
                        if (bytes > release.apkSize) throw IOException("The download is bigger than GitHub said.")
                        // About every half percent, so the progress bar doesn't redraw for every packet.
                        if (bytes - shown >= release.apkSize / 200) {
                            shown = bytes
                            _install.value = Install.Downloading(release, bytes)
                        }
                    }
                }
            }
            if (file.length() != release.apkSize) throw IOException("The download stopped before the end.")
            _install.value = Install.Downloading(release, bytes)
            return file
        } finally {
            connection.disconnect()
            this.connection = null
        }
    }

    /** Before Android's installer: is it Stow, signed with the key the installed app is? */
    @Suppress("DEPRECATION")
    private fun verify(apk: File, release: Release) {
        val pm = context.packageManager
        val archive = pm.getPackageArchiveInfo(apk.path, PackageManager.GET_SIGNING_CERTIFICATES)
            ?: throw IOException("The download isn't an app Android can read.")
        if (archive.packageName != context.packageName) throw IOException("The download for ${release.version} isn't Stow.")
        val installed = pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        val theirs = signers(archive)
        val ours = signers(installed)
        if (theirs.isNotEmpty() && ours.isNotEmpty() && theirs.intersect(ours).isEmpty()) throw IOException(SIGNATURE_MISMATCH)
    }

    private fun signers(info: PackageInfo): Set<Signature> {
        val signing = info.signingInfo ?: return emptySet()
        val list = if (signing.hasMultipleSigners()) signing.apkContentsSigners else signing.signingCertificateHistory
        return list.orEmpty().toSet()
    }

    private suspend fun install(apk: File, release: Release) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
            setInstallReason(PackageManager.INSTALL_REASON_USER)
        }
        val id = installer.createSession(params)
        sessionId = id
        installer.openSession(id).use { session ->
            session.openWrite("base.apk", 0, apk.length()).use { output ->
                apk.inputStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                    }
                }
                session.fsync(output)
            }
            coroutineContext.ensureActive()
            // Mutable: the installer adds the status (and its confirm screen) to this intent.
            val status = Intent(context, InstallReceiver::class.java).setAction(InstallReceiver.ACTION).putExtra(EXTRA_VERSION, release.version)
            val pending = PendingIntent.getBroadcast(context, id, status, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            _install.value = Install.Installing(release)
            session.commit(pending.intentSender)
            sessionId = null
        }
    }

    private fun abandon(id: Int) {
        sessionId = null
        runCatching { context.packageManager.packageInstaller.abandonSession(id) }
    }

    /** The installer's answer, from [InstallReceiver]. */
    fun onInstallStatus(intent: Intent) {
        val release = when (val state = _install.value) {
            is Install.Installing -> state.release
            is Install.Confirm -> state.release
            else -> available
        } ?: return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        Log.i(TAG, "Install of ${release.version}: status $status ${message.orEmpty()}")
        _install.value = when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION ->
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)?.let { Install.Confirm(release, it) }
                    ?: Install.Failed(release, "Android didn't show its install screen.")
            PackageInstaller.STATUS_SUCCESS -> Install.Idle
            // You tapped Cancel on Android's screen.
            PackageInstaller.STATUS_FAILURE_ABORTED -> Install.Idle
            else -> Install.Failed(release, installFailure(status, message))
        }
    }

    private fun installFailure(status: Int, message: String?): String {
        val detail = message.orEmpty()
        return when {
            status == PackageInstaller.STATUS_FAILURE_CONFLICT && (detail.contains("signature", ignoreCase = true) || detail.contains("UPDATE_INCOMPATIBLE")) ->
                SIGNATURE_MISMATCH
            detail.contains("DOWNGRADE") -> "The download is an older version than the one installed."
            status == PackageInstaller.STATUS_FAILURE_STORAGE -> "Not enough free space to install the update."
            status == PackageInstaller.STATUS_FAILURE_BLOCKED -> "Android blocked the update."
            else -> "Android couldn't install the update" + (if (detail.isNotBlank()) ": $detail" else ".")
        }
    }

    private fun open(url: String, readTimeoutMs: Int = 20_000): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = readTimeoutMs
            instanceFollowRedirects = true // GitHub's asset links redirect to its file storage.
            setRequestProperty("User-Agent", "Stow-Android/$currentVersion")
        }

    private fun describe(e: Exception): String = when (e) {
        is UnknownHostException -> "No connection."
        is java.net.SocketTimeoutException -> "GitHub didn't answer."
        is IOException -> e.message?.takeIf { it.endsWith(".") } ?: "Couldn't reach GitHub."
        else -> e.message?.takeIf { it.isNotBlank() } ?: "Something went wrong."
    }

    private fun kotlin.coroutines.CoroutineContext.isActiveJob() = this[Job]?.isActive != false

    companion object {
        private const val TAG = "StowUpdate"
        const val FEED_URL = "https://api.github.com/repos/kimdobinn/stow/releases/latest"
        const val CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000L
        private const val DIR = "updates"
        private const val EXTRA_VERSION = "version"
        const val SIGNATURE_MISMATCH = "This update isn't signed with the same key as the installed app, so Android won't install it over it."
    }
}
