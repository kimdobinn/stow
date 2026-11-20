package dev.stow.android.player

import android.app.PendingIntent
import android.content.Intent
import android.content.SharedPreferences
import dev.stow.android.data.Prefs
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import dev.stow.android.MainActivity

/** Plays in the background and on the lock screen, with the system media controls. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(StreamSourceFactory(this))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .setSeekBackIncrementMs(5_000)
            .setSeekForwardIncrementMs(5_000)
            .build()
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        session = MediaSession.Builder(this, player).setSessionActivity(open).build()
        // Autoplay is off unless turned on: each video stops at its end ("done" screen).
        val prefs = getSharedPreferences("stow", MODE_PRIVATE)
        player.pauseAtEndOfMediaItems = !prefs.getBoolean(Prefs.KEY_AUTOPLAY, false)
        autoplayListener = SharedPreferences.OnSharedPreferenceChangeListener { changed, key ->
            if (key == Prefs.KEY_AUTOPLAY) player.pauseAtEndOfMediaItems = !changed.getBoolean(key, false)
        }
        prefs.registerOnSharedPreferenceChangeListener(autoplayListener)
    }

    /** Kept here: SharedPreferences only holds listeners weakly. */
    private var autoplayListener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /** Swiping the app away stops playback unless something is playing. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = session?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }
}
