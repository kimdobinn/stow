# Stow for iPhone

The iPhone version of Stow's phone app. It does what the Android app does: it pairs with the Mac
by QR code, shows the Mac's channels, YouTube's Home and Subscriptions, searches and channel pages,
and downloads what the Mac sends, or what you pick on the phone, so you can watch it offline.

It also works without the Mac: on first launch it asks "How do you want to use Stow?", and **Use on
its own** makes the phone follow channels and check them for new videos itself, with no Firebase
at all (see [Standalone mode](#standalone-mode)).

It is a native SwiftUI app (iOS 17 and later, iPhone only, bundle id `dev.stow.ios`), meant to be
sideloaded with SideStore or AltStore on a free Apple ID. The Android app in `android/` is the
reference: this one ports its behaviour, not its code.

## Building

You need Xcode 26 (iOS 26 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Run everything from the repository root.

1. **Python and yt-dlp.** Download the embedded CPython (BeeWare's Python-Apple-support, which
   is CPython's official iOS build), yt-dlp, yt-dlp-ejs and certifi into `ios/Vendor/`. Every
   download is pinned and checked against its sha256.

   ```sh
   ios/scripts/fetch-python.sh            # --force downloads again
   ```

   To update yt-dlp, change `YTDLP_VERSION` and its sha256 in the script (and yt-dlp-ejs to the
   version yt-dlp pins), then run it again.

2. **Firebase settings.** Write `ios/Stow/Config/Firebase.plist` (project id and API key) from
   the Android app's `google-services.json`. The plist is git-ignored, and the script never
   prints the key. Without it the app still builds and runs in demo mode, and pairing says the
   build has no Firebase settings.

   ```sh
   ios/scripts/firebase-config.sh         # [google-services.json [output.plist]]
   ```

3. **The Xcode project.** It's generated from `ios/project.yml`; never edit `Stow.xcodeproj` by
   hand (it's git-ignored).

   ```sh
   cd ios && xcodegen generate
   ```

4. **Build, test, run.**

   ```sh
   # Simulator build and the app's tests (Swift Testing, hosted in the app)
   xcodebuild -project Stow.xcodeproj -scheme Stow -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
       -derivedDataPath build/sim test

   # The data layer's tests (no simulator needed)
   cd StowKit && swift test

   # Device build, unsigned (SideStore/AltStore sign it when installing)
   xcodebuild -project Stow.xcodeproj -scheme Stow -sdk iphoneos -configuration Release \
       -destination 'generic/platform=iOS' -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build
   ```

   To publish a version for SideStore and AltStore: bump `CFBundleShortVersionString` and
   `CFBundleVersion` in `project.yml`, commit and push, then run `ios/release.sh`. It builds
   `Stow-<version>.ipa` (unsigned; SideStore signs it with your Apple ID), publishes it as the GitHub
   pre-release `ios-v<version>`, and adds it to `source.json`. The app is about 54 MB, most of it
   Python.

### Launch arguments

For trying the app in the simulator without a Mac or Firebase:

| Argument | What it does |
| --- | --- |
| `-demo` | Demo mode: sample channels and videos (the same as Android's `DemoData`), no Firebase. A file named `demo` in Application Support does the same. |
| `-tab downloads\|subscriptions` | Opens on that tab. |
| `-open settings,report,…` | Opens screens: `search`, `settings`, `report`, `groups`, `channels`, `ytdlp`, `channel:<id>`, `group:<id>`, `playlist:<id\|first>`, `save:<video id>`, `update` (the update sheet, once a check finds one). |
| `-search <query>` | Runs a search once. |
| `-play <video id>` | Opens the player on that video. |
| `-theme system\|light\|dark\|paper`, `-calm YES`, `-grayscale YES`, `-downloadQuality p480` | Settings for this launch only. |
| `-updates-url <url>` | Debug builds only: the update check reads this releases list instead of GitHub's, at every launch (a fake one served from the Mac). |
| `-ytdlp-selftest [-ytdlp-selftest-exit] [-ytdlp-nojs] [-ytdlp-debug]` | Runs yt-dlp's self-test against public videos and prints `SELFTEST PASS/FAIL` lines. |
| `-standalone` | Debug builds: standalone mode, unless paired (then it logs "-standalone ignored: paired" and never unpairs). A file named `standalone` in Application Support does the same. `-demo` wins over it. |
| `-choose-mode` | Debug builds: forgets the mode when not paired, so the Welcome screen shows. |
| `-standalone-reset` | Debug builds: deletes standalone.json and the Keychain's YouTube cookies before start. |
| `-channels <ref>,<ref>` | Debug builds, standalone: follows each (UC id, @handle or URL) at launch, skipping followed ones, and checks them. |
| `-cookies <path>` | Debug builds, standalone: imports that cookies.txt (a path in the app's data container, e.g. `Library/Application Support/test-cookies.txt`) without asking YouTube first, so fake cookies get stored. |

`-open` also takes `account`, `channels-manage`, `import`, `add-channel` and `signin` (standalone mode's screens).

```sh
xcrun simctl launch <simulator> dev.stow.ios -demo -open search -search "big buck bunny"
log stream --level debug --predicate 'subsystem == "dev.stow.ios"'   # categories: repository, downloads, player, standalone, sign-in

# Standalone mode with NASA followed, from scratch
xcrun simctl launch <simulator> dev.stow.ios -standalone -standalone-reset -channels UCLA_DiR1FfKNvjuUpBHmylQ
```

## Standalone mode

"Use on its own" (the Welcome screen, Settings › Mac › "Use on its own", or the pair screen's "Use
on its own instead") makes the phone do the Mac's jobs. The spec both phones follow is the same
(Android 0.9.0, iPhone 0.2.0); what the iPhone does:

- **Mode.** `appMode` in UserDefaults (`mac` or `standalone`), worked out at launch from the
  preferences only (`AppMode.resolve`): an install paired before 0.2.0 becomes `mac` and stays
  paired. In standalone the Repository has no `Remote` at all, and its `FirebaseGuard` refuses
  (and in debug builds asserts on) any Firebase request.
- **Channels** live in `Application Support/standalone.json` (one schema with Android; unknown keys
  are kept), with each channel's 30 newest videos. Follow from a channel page, a video's ⋯ menu,
  Settings › Channels (a URL, @handle, channel ID or video link) or, signed in, Import from YouTube
  (nothing is picked for you). Groups are stored there too; a group's channels are followed.
- **Checks** (`StandaloneEngine`, `CheckPlan`): uploads from the `UULF` RSS feed over plain HTTP
  (if YouTube's playlist feeds keep answering 5xx, the Videos tab through yt-dlp, whose dates are
  approximate: kept in the tab's order, and never replacing a date already known), past streams
  from the Live tab every 6 hours, members-only videos hourly when signed in. At launch, back on
  screen and every minute while open when 14 minutes have passed since the last check started (a
  check that couldn't reach YouTube doesn't count), on pull-to-refresh, and in the background
  refresh task (only the RSS round and a due watched sync: iOS gives it about 30 s). HTTP 429 or
  5xx backs automatic checks off (30 minutes, doubling to 4 hours). A Live tab listed without each
  entry's `live_status` isn't counted as read.
- **YouTube sign-in is optional**: Google's login in a non-persistent web view with Mobile
  Safari's user agent, or a cookies.txt file. The cookies live only in the Keychain
  (`dev.stow.ios.youtube`, this device only). Signed in, the phone reads YouTube's Home and
  Subscriptions, members-only videos and syncs watched with YouTube's history; when YouTube stops
  taking the cookies, a notification and a Home banner say so once.
- **Nothing downloads by itself**, as with the Mac since auto-download went: downloads are what you tap.
- Switching to the Mac signs the phone out of YouTube and keeps standalone.json for later;
  switching back from the Mac can copy the Mac's channels, recent videos and groups.

## How it's built

```
ios/
  project.yml            XcodeGen: the Stow app, its test bundle, the StowKit package
  scripts/               fetch-python.sh, install-python.sh (build phase), firebase-config.sh, make-icon.swift
  Vendor/                Python.xcframework and site-packages (fetched, git-ignored)
  StowKit/               Swift package: everything that isn't UI or yt-dlp
    Sources/StowKit/
      Models/            Video, SentVideo, LocalVideo, VideoItem…; YouTube listings, feeds, comments, crypto
      Firebase/          anonymous auth and Firestore over REST (no Firebase SDK); Remote = Stow's layout
      Store/             Prefs (UserDefaults), LocalStore (downloads), playlists, watch stats
      Sync/              Repository (the app's state), DownloadManager, YouTubeTool protocol, DemoData
      Standalone/        standalone mode: the engine, check plan, RSS, channel resolver, subscriptions import
      Account/           Netscape cookies.txt, the Keychain cookie vault, the sign-in's state
    Tests/StowKitTests/  stubbed Firestore (URLProtocol), fake YouTube, fixtures
  Stow/
    App/                 @main, AppServices (wiring), background tasks, YtDlpTool (StowKit ↔ yt-dlp), launch arguments
    YtDlp/               embedded CPython bridge (C), stow_ytdlp.py, YtDlp client, AVFoundation merger
    Playback/            PlaybackController (AVPlayer), Now Playing, Picture in Picture, scrub frames
    Downloads/           BackgroundDownloads (background time for a running download)
    UI/                  Shell (tabs, routes), Components, Feeds (Home, Subscriptions, groups), Player,
                         Downloads, Search, Channel, Library (playlists), Settings, Pairing (QR scanner)
  StowTests/             app tests by area: YtDlp, Shell, Player, Screens
```

- **StowKit** holds the data and sync logic and knows nothing about UIKit or Python, so it's
  tested with `swift test` on the Mac. `Repository` is `@Observable`; every screen reads it from
  the environment. It talks to YouTube only through the `YouTubeTool` protocol.
- **yt-dlp** runs in the app on an embedded CPython 3.14. One Swift thread starts the
  interpreter; each call runs on its own Python thread, and the GIL is released during network
  waits. yt-dlp's JavaScript challenges run in JavaScriptCore (Android bundles QuickJS). The
  build phase `install-python.sh` copies the standard library into the app and turns each
  compiled module into a framework, as CPython's iOS guide requires.
- **The app** wires StowKit to yt-dlp (`YtDlpTool`), keeps the polling and background tasks
  going (`AppServices`, `BackgroundWork`, `BackgroundDownloads`), and draws the screens. `Shell`
  holds navigation, the player request, sheets and toasts.

## What's different from Android, and why

- **No push.** A sideloaded app on a free Apple ID can't use APNs (or App Groups or extensions),
  so the phone has no FCM token (`fcmToken` is null when pairing) and polls Firestore instead:
  at launch, when the app comes back to the screen, every 60 seconds while it's open, on
  pull-to-refresh, and from a background app refresh task (`dev.stow.ios.refresh`), which iOS
  runs when it chooses. A video the Mac sends shows up within a minute while Stow is open, and
  otherwise the next time iOS gives it time.
- **Polls read only what changed.** Firestore's free plan bills every document read, so a poll
  asks for documents with `updatedAt` after the newest one it has seen. Every 15 minutes, and on
  pull-to-refresh, it reads everything; that's when deleted channels and videos go.
- **Firebase over REST.** There's no Firebase SDK: anonymous sign-in and token refresh go to the
  Identity Toolkit and Secure Token APIs, and reads and writes to Firestore's REST API, with the
  same security rules (`firebase/firestore.rules`). The SDK's offline queue doesn't exist here,
  so a download the phone asks for (picked from a search, a channel page or YouTube's feeds) is
  kept on the phone and filed again on every poll until Firestore has it.
- **The phone's download state isn't reported.** The Android phone owns each video's `phone`
  field on the Mac; the iPhone never writes it. It writes only what the rules allow: watched
  state, download requests (`sentBy: "phone"`), group edits and pull-to-refresh requests.
  Deleting a download on the iPhone doesn't tell the Mac.
- **Downloads stop at 1080p, H.264 and AAC.** There is no ffmpeg on iOS. yt-dlp downloads the
  video and audio separately and AVFoundation merges them into an .mp4 without re-encoding, so
  the video must be H.264, which YouTube offers only up to 1080p. Settings offers 1080p, 720p
  and 480p. Streams play YouTube's HLS manifests in AVPlayer, also capped at 1080p.
- **Background limits.** iOS gives a running download only a short while (often about 30
  seconds) after you leave the app. If that runs out, the download stops cleanly,
  keeps what it has, and a quiet notification says "Open Stow to finish the download"; it
  resumes when you open Stow, or when iOS runs the background processing task
  (`dev.stow.ios.downloads`), often overnight while charging. A background `URLSession` isn't
  used because yt-dlp does the downloading in Python.
- **Updates go through SideStore.** An app can't install itself, so Stow only looks: once a day
  (at launch, when it comes back, or in the background refresh) and from Settings › About, it reads
  GitHub's releases, keeps the iPhone ones (`ios-v*` pre-releases, not Android's `v*` or the Mac's
  `mac-v*`) and compares the newest with its own version. A new one shows in Settings and as a
  one-line banner on Home (closable, per version). "Update in SideStore" opens
  `sidestore://install?url=<Stow-x.y.z.ipa>` (AltStore's `altstore://install?url=` when SideStore
  isn't there, the release page when neither is); SideStore asks before it installs. SideStore can
  also update Stow from its Updates list, from `source.json`.
- **yt-dlp updates with the app.** Android updates yt-dlp by itself every day; here the pinned
  version changes only when you run `fetch-python.sh` with a new version and rebuild.
- **Not on iPhone:** the Mac's alarm remote and anything else that needs push, and Android's
  check for low storage before a download. Several downloads at once aren't supported; they run
  one at a time.

## Testing

- **StowKit** (`cd ios/StowKit && swift test`): Firestore value decoding against real REST
  responses, the REST client against a `URLProtocol` stub (sign-up, token refresh, paging,
  commits, transactions, refused writes), the Mac's encryption, the ported Android tests for
  listings and feeds, the stores, and the Repository end to end against a stubbed Firestore and a
  fake YouTube: polling and merging, unpairing, pairing (including a reused QR code), downloads
  with retries, Wi-Fi rules and pauses, and the phone's own requests (a failed request filed on a
  later poll, a deleted one staying deleted, downloads still listed after a relaunch).
- **Standalone mode** (in `swift test`): the mode migration, cookies.txt format and parse, the
  channel resolver's inputs, the channel page, RSS, past streams, members and access parsers,
  the subscriptions walker and SAPISIDHASH, failure classes, the check plan, the merge rules,
  standalone.json, the import picker, and the Repository end to end on a stubbed youtube.com and a
  fake yt-dlp with Firebase's hosts as a tripwire (follow, pull, backoff, groups, downloads,
  expiry and sign-out, mode switches both ways).
- **The app** (`xcodebuild … test`): the Python bridge (threads, cancellation, progress),
  yt-dlp's output parsing, merging H.264 and AAC into an .mp4, the Shell's navigation and
  playback rules on a demo Repository, the player on generated files (resume, autoplay, speed,
  seeking, marking watched), and the screens' logic. The Keychain token store is tested inside
  the app, where the Keychain is available.
- **yt-dlp against YouTube**: `-ytdlp-selftest` runs info, search, a channel, comments, an HLS
  stream, a download and merge, and cancelling, against public videos, in the simulator.
- **By hand, in the simulator, in demo mode.** Nothing in the tests or scripts talks to the real
  Firebase project; demo mode needs none. Picture in Picture, the lock screen controls,
  background tasks and the camera can't be checked in the simulator.
