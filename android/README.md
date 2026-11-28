# Stow for Android

Two ways to work, picked on the first screen (and switched in Settings › Mac):

- **Use with my Mac:** downloads the videos the Mac sends (Firebase push → yt-dlp) and plays
  them offline, in the background and on the lock screen.
- **Use on its own (standalone):** the phone follows channels and checks them itself, with no
  Firebase at all. Signing in to YouTube on the phone is optional (Home, Subscriptions,
  members-only videos, watched sync).

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
- `update/`: once a day (and from Settings › About) asks GitHub for the latest release
  (`/releases/latest`, which skips the iPhone's and Mac's pre-releases; tag `v<version>` with an
  `.apk`), and on Update downloads it and installs it with Android's package installer. Debug
  builds read the feed URL from `files/update-feed` if it exists, to test against a local server.

## Standalone mode

- `standalone/Standalone.kt` is the engine (plain Kotlin, tested on the JVM): channels, checks,
  YouTube's feeds, member access, watched sync. Everything lives in `files/standalone.json`
  (`StandaloneStore`); the YouTube cookies in `files/youtube/cookies.bin`, encrypted with an
  AndroidKeyStore AES-GCM key (`account/CookieVault`), excluded from backups.
- Checks: `CheckWorker` (WorkManager, unique `standalone-check`, about every 15 minutes while
  online), at launch, back on screen (ProcessLifecycleOwner) and pull to refresh. `CheckPlan`
  decides which feeds each check reads: uploads from RSS (`UULF…`, long-form only) every time,
  past streams (yt-dlp Live tab + `UULV` RSS) every 6 h, members-only feeds hourly when signed in,
  YouTube's Home and Subscriptions (`:ytrec`, `:ytsubs`) every 20 min (2 h in the background).
  HTTP 429/5xx backs off for 30 min, doubling up to 4 h (pull ignores it). When YouTube's
  playlist RSS feeds answer 5xx (they did for days in Nov 2026) uploads come from the Videos tab
  through yt-dlp instead.
- Sign-in: `ui/SignInScreen.kt` (WebView with Chrome's user agent, no `X-Requested-With`; the
  cookies go to the vault and the web view is wiped) or a cookies.txt file from a desktop browser.
- Firebase is untouched: `Repository.remote` is created only in Mac mode (debug builds throw
  "FIREBASE TOUCHED in standalone" otherwise), FCM auto-init is off in the manifest and turned on
  only for paired installs, `SyncWorker` and the push service do nothing unless paired.
- Installs paired before 0.9.0 resolve to Mac mode and stay paired (`AppMode.resolve`).

### Debug hooks (debug builds only)

Files in the app's `files/` folder, read at start (`Repository.start()`):

| File | Effect |
|---|---|
| `standalone` | Standalone mode unless paired (kept) |
| `choose-mode` | Back to the first screen unless paired (deleted) |
| `standalone-reset` | Deletes standalone.json and the YouTube sign-in (deleted) |
| `standalone-channels` | One channel per line (UC id, @handle or URL), followed at start (deleted) |
| `debug-cookies.txt` | Imported as the YouTube sign-in without checking it with YouTube (deleted right away) |

```
adb -s emulator-5554 push fake-cookies.txt /data/local/tmp/c.txt
adb -s emulator-5554 shell run-as dev.stow.android cp /data/local/tmp/c.txt files/debug-cookies.txt
adb -s emulator-5554 shell rm /data/local/tmp/c.txt
```

`app/src/test/resources/fake-cookies.txt` is obviously fake (the next check marks it signed out).
The intent extra `stow.route` (`settings`, `account`, `channels`, `import`, `search`) opens a
screen at launch: `adb shell am start -n dev.stow.android/.MainActivity --es stow.route channels`.
