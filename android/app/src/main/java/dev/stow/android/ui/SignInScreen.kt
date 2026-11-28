package dev.stow.android.ui

import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.CookieManagerCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import dev.stow.android.BuildConfig
import dev.stow.android.account.Cookie
import dev.stow.android.account.NetscapeCookies
import dev.stow.android.account.SignInRules
import dev.stow.android.standalone.Standalone
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The sign-in web view's cookies and storage: read once signed in, then wiped (WebView data isn't encrypted; the vault holds the only copy). */
object SignInWeb {
    /** Deletes every cookie and all web storage the web view kept; `then` runs once the cookies are gone. */
    fun clearAll(then: (() -> Unit)? = null) {
        val clear = {
            runCatching {
                CookieManager.getInstance().removeAllCookies {
                    CookieManager.getInstance().flush()
                    then?.invoke()
                }
                WebStorage.getInstance().deleteAllData()
            }.onFailure {
                Log.w("Stow", "Couldn't clear the sign-in web data", it)
                then?.invoke()
            }
            Unit
        }
        if (Looper.myLooper() == Looper.getMainLooper()) clear() else Handler(Looper.getMainLooper()).post(clear)
    }

    /**
     * The youtube.com and google.com cookies. With `GET_COOKIE_INFO` they come with their real
     * domain, path, expiry and flags; without it only as name=value pairs (see
     * [NetscapeCookies.fromCookieHeader]).
     */
    fun export(now: Long = System.currentTimeMillis()): List<Cookie> {
        val manager = CookieManager.getInstance()
        val cookies = ArrayList<Cookie>()
        val detailed = WebViewFeature.isFeatureSupported(WebViewFeature.GET_COOKIE_INFO)
        for (url in SignInRules.EXPORT_URLS) {
            val host = Uri.parse(url).host ?: continue
            if (detailed) {
                runCatching { CookieManagerCompat.getCookieInfo(manager, url) }.getOrNull()?.forEach { info ->
                    NetscapeCookies.parseCookieInfo(info, host, now)?.let(cookies::add)
                }
            } else {
                manager.getCookie(url)?.let { cookies += NetscapeCookies.fromCookieHeader(it, host, now) }
            }
        }
        return NetscapeCookies.deduplicate(cookies).filter(NetscapeCookies::isKept)
    }
}

/**
 * Settings › Sign in to YouTube: Google's own sign-in page, full screen. Once YouTube has a
 * session (the Mac's test), its cookies go to the vault and the web view's copy is wiped. Google
 * sometimes refuses web views; the cookies.txt import is always a tap away.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun SignInScreen(standalone: Standalone, onImportFile: () -> Unit, onDone: (String) -> Unit, onCancel: () -> Unit) {
    val scope = rememberCoroutineScope()
    var blocked by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var saving by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var webView by remember { mutableStateOf<WebView?>(null) }
    var finished by remember { mutableStateOf(false) }
    val sessions = remember { SignInRules.Sessions() }

    fun wipe(then: (() -> Unit)? = null) {
        webView?.clearCache(true)
        SignInWeb.clearAll(then)
    }

    /** After a refused sign-in: Google's login again, from an emptied cookie store, without leaving the screen. */
    fun startAgain() {
        val view = webView ?: return
        view.stopLoading()
        blocked = false
        wipe { if (!finished) view.loadUrl(SignInRules.LOGIN_URL) }
        Log.i("Stow", "Sign-in refused: starting again")
    }

    // Each sign-in starts clean, and nothing is left behind however the screen closes.
    DisposableEffect(Unit) {
        onDispose {
            finished = true
            webView?.let { it.stopLoading(); it.clearCache(true); it.destroy() }
            SignInWeb.clearAll()
        }
    }

    fun check() {
        val view = webView ?: return
        if (finished || saving) return
        val host = view.url?.let { Uri.parse(it).host }
        val now = System.currentTimeMillis()
        val fingerprint = if (host.orEmpty().endsWith("youtube.com")) NetscapeCookies.sessionFingerprint(SignInWeb.export(now), now) else null
        if (!sessions.take(host, loading || view.progress < 100, fingerprint)) return
        saving = true
        scope.launch {
            delay(1_000)
            val text = NetscapeCookies.format(SignInWeb.export(), System.currentTimeMillis())
            wipe()
            when (val result = standalone.signIn(text, Standalone.SOURCE_WEB)) {
                Standalone.SignInResult.Done -> {
                    finished = true
                    onDone("Signed in to YouTube")
                }
                is Standalone.SignInResult.Failed -> {
                    failure = result.message
                    saving = false
                    // A fresh login behind the dialog, so signing in again works without leaving.
                    startAgain()
                }
            }
        }
    }

    // WebView has no cookie observer: look every second while the screen is open.
    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000)
            check()
        }
    }

    Column(Modifier.fillMaxSize().background(Stow.colors.background)) {
        Box(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 8.dp, vertical = 6.dp)) {
            TextButton(onClick = onCancel, modifier = Modifier.align(Alignment.CenterStart)) { Text("Cancel", color = Stow.colors.accent) }
            Text("Sign in to YouTube", style = StowType.headline, color = Stow.colors.text, modifier = Modifier.align(Alignment.Center))
        }
        HorizontalDivider(thickness = 0.5.dp, color = Stow.colors.divider)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            AndroidView(
                factory = { context ->
                    WebStorage.getInstance().deleteAllData()
                    WebView(context).apply {
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.userAgentString = SignInRules.userAgent(WebSettings.getDefaultUserAgent(context))
                        if (BuildConfig.DEBUG) Log.d("Stow", "Sign-in user agent: ${settings.userAgentString}")
                        if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
                            WebSettingsCompat.setRequestedWithHeaderOriginAllowList(settings, emptySet())
                        }
                        CookieManager.getInstance().setAcceptCookie(true)
                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                        webViewClient = object : WebViewClient() {
                            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                                loading = true
                                blocked = SignInRules.isBlocked(url, view.title)
                            }

                            override fun onPageFinished(view: WebView, url: String?) {
                                loading = false
                                blocked = SignInRules.isBlocked(url, view.title)
                                check()
                            }
                        }
                        webView = this
                        // Starts from no cookies at all, so the session found later is this sign-in's.
                        CookieManager.getInstance().removeAllCookies { loadUrl(SignInRules.LOGIN_URL) }
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
            // The "won't sign in" card drops in, and the checking overlay fades, instead of popping.
            Appear(blocked, Modifier.align(Alignment.TopCenter),
                   enter = fadeIn(tween(Motion.SHORT)) + slideInVertically(Motion.enter()) { -it / 2 }, exit = fadeOut(tween(Motion.SHORT))) {
                Column(Modifier.fillMaxWidth().padding(12.dp).clip(RoundedCornerShape(14.dp))
                           .background(Stow.colors.raised).padding(16.dp)) {
                    Text("Google won't sign in inside apps on this phone. Use a cookies.txt file instead.",
                         style = StowType.subheadline, color = Stow.colors.text)
                    TextButton(onClick = onImportFile) { Text("Use a cookies.txt file", color = Stow.colors.accent, fontWeight = FontWeight.SemiBold) }
                }
            }
            Appear(saving, Modifier.fillMaxSize(), enter = fadeIn(tween(Motion.SHORT)), exit = fadeOut(tween(Motion.SHORT))) {
                Box(Modifier.fillMaxSize().background(Stow.colors.background.copy(alpha = 0.85f)), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(color = Stow.colors.accent)
                        Spacer(Modifier.size(12.dp))
                        Text("Checking with YouTube…", style = StowType.subheadline, color = Stow.colors.secondaryText)
                    }
                }
            }
        }
        HorizontalDivider(thickness = 0.5.dp, color = Stow.colors.divider)
        Row(Modifier.fillMaxWidth().clickable(onClick = onImportFile).navigationBarsPadding().padding(16.dp),
            horizontalArrangement = Arrangement.Center) {
            Text("Trouble signing in? ", style = StowType.footnote, color = Stow.colors.secondaryText)
            Text("Use a cookies.txt file instead", style = StowType.footnote, color = Stow.colors.accent, fontWeight = FontWeight.SemiBold)
        }
    }
    failure?.let { message ->
        AlertDialog(onDismissRequest = { failure = null }, title = { Text("Not signed in") }, text = { Text(message) },
                    confirmButton = { TextButton(onClick = { failure = null }) { Text("OK") } })
    }
}

/**
 * "Use a cookies.txt file": the help, then Android's file picker, then the same checks as the web
 * sign-in. The picked file is only read, never changed or deleted.
 */
class CookiesImport(val start: () -> Unit)

@Composable
fun rememberCookiesImport(standalone: Standalone, notify: (String) -> Unit, onSignedIn: () -> Unit = {}): CookiesImport {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var explaining by remember { mutableStateOf(false) }
    var checking by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        checking = true
        scope.launch {
            val text = runCatching {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
                }
            }.getOrNull()
            val result = if (text == null) Standalone.SignInResult.Failed("Couldn't read that file.")
                         else standalone.signIn(text, Standalone.SOURCE_FILE)
            checking = false
            when (result) {
                Standalone.SignInResult.Done -> {
                    notify("Signed in to YouTube")
                    onSignedIn()
                }
                is Standalone.SignInResult.Failed -> failure = result.message
            }
        }
    }
    if (explaining) {
        AlertDialog(
            onDismissRequest = { explaining = false },
            title = { Text("Use a cookies.txt file") },
            text = { Text(SignInRules.HELP) },
            confirmButton = {
                TextButton(onClick = { explaining = false; picker.launch(arrayOf("text/plain", "*/*")) }) { Text("Choose File") }
            },
            dismissButton = { TextButton(onClick = { explaining = false }) { Text("Cancel") } },
        )
    }
    if (checking) {
        AlertDialog(
            onDismissRequest = {},
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Stow.colors.accent)
                    Spacer(Modifier.width(12.dp))
                    Text("Checking with YouTube…")
                }
            },
            confirmButton = {},
        )
    }
    failure?.let { message ->
        AlertDialog(onDismissRequest = { failure = null }, title = { Text("Not signed in") },
                    text = { Text(message, textAlign = TextAlign.Start) },
                    confirmButton = { TextButton(onClick = { failure = null }) { Text("OK") } })
    }
    return remember { CookiesImport { explaining = true } }
}
