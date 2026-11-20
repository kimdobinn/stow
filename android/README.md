# Stow for Android

Downloads the videos the Mac sends (Firebase push → yt-dlp) and plays them offline,
in the background and on the lock screen.

- **Build:** `./gradlew :app:assembleRelease` → `app/build/outputs/apk/release/app-release.apk`
  (needs `app/google-services.json`, a copy of `../firebase/google-services.json`, and the
  signing key in `keystore/`; both stay out of git).
- **Install:** `adb install -r app/build/outputs/apk/release/app-release.apk`. Updates must be
  signed with the same key (`keystore/stow.jks`) or Android refuses them; keep a backup of it.
- **Pair:** on the Mac, Stow › Phone › Pair a Phone, then scan the code with the app (or the
  camera; it opens `stow://pair?…`).

## How it works

- `data/Remote.kt`: Firebase (anonymous sign-in; Firestore videos/channels/members/secrets).
- `data/Repository.kt`: the Mac's videos merged with local download state (`LocalStore`).
- `sync/`: FCM wakes `SyncWorker`, which queues one `DownloadWorker` per video (Wi-Fi only by
  default). yt-dlp comes from youtubedl-android (bundled Python, ffmpeg and QuickJS for
  YouTube's JS challenges) and updates itself daily.
- `player/PlaybackService.kt`: Media3 session service for background and lock-screen playback.
- Cookies (decrypted with the pairing key) are used only for members-only videos.
