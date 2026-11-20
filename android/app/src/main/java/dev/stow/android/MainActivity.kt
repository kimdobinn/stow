package dev.stow.android

import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import dev.stow.android.data.PairState
import dev.stow.android.ui.LibraryScreen
import dev.stow.android.ui.PairScreen
import dev.stow.android.ui.PlayerScreen
import dev.stow.android.ui.SettingsScreen
import dev.stow.android.ui.StowTheme

class MainActivity : ComponentActivity() {
    private val repository get() = (application as StowApplication).repository

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handle(intent)
        setContent {
            StowTheme {
                Surface(Modifier.fillMaxSize()) { App() }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** stow://pair?… opened from the phone's camera app. */
    private fun handle(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme == "stow" && data.host == "pair") repository.pair(data.toString())
    }

    @androidx.compose.runtime.Composable
    private fun App() {
        val pairState by repository.pairState.collectAsStateWithLifecycle()
        val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
        LaunchedEffect(Unit) { notifications.launch(Manifest.permission.POST_NOTIFICATIONS) }

        if (pairState != PairState.Paired) {
            PairScreen(pairState, onScanned = repository::pair)
            return
        }
        val items by repository.items.collectAsStateWithLifecycle()
        val wifiOnly by repository.prefs.wifiOnly.collectAsStateWithLifecycle()
        val nav = rememberNavController()
        NavHost(nav, startDestination = "library") {
            composable("library") {
                LibraryScreen(
                    items = items,
                    onPlay = { nav.navigate("player/${it.id}") },
                    onSetWatched = { item, watched -> repository.setWatched(item.id, watched) },
                    onDelete = { repository.deleteDownload(it.id) },
                    onRetry = { repository.retry(it.id) },
                    onSettings = { nav.navigate("settings") },
                )
            }
            composable("player/{id}") { entry ->
                val id = entry.arguments?.getString("id")
                val item = items.firstOrNull { it.id == id }
                if (item == null || !item.isPlayable) {
                    LaunchedEffect(Unit) { nav.popBackStack() }
                } else {
                    PlayerScreen(
                        item = item,
                        onPosition = { position, duration -> repository.savePosition(item.id, position, duration) },
                        onWatched = { repository.setWatched(item.id, true) },
                        onSetWatched = { repository.setWatched(item.id, it) },
                        onClose = { nav.popBackStack() },
                    )
                }
            }
            composable("settings") {
                SettingsScreen(repository, wifiOnly, onBack = { nav.popBackStack() })
            }
        }
    }
}
