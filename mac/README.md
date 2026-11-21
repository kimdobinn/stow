# Stow for Mac

A Mac app that watches chosen YouTube channels for new long-form and members-only videos,
keeps an Inbox, and wakes you up with the morning's videos: at the alarm time it plays them
fullscreen with sound, streamed live from YouTube (ad-free, SponsorBlock segments skipped).
It stores no videos. Design notes are in [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- macOS 26, Xcode 26
- `brew install xcodegen yt-dlp mpv` (tools are looked up in /opt/homebrew/bin, /usr/local/bin and /usr/bin)

## Build and run

The Xcode project is generated from `project.yml`; don't edit `Stow.xcodeproj` by hand.

```sh
cd mac
xcodegen generate
xcodebuild -project Stow.xcodeproj -scheme Stow -configuration Debug -derivedDataPath .build build
open .build/Build/Products/Debug/Stow.app
```

Or run `xcodegen generate`, then `open Stow.xcodeproj` and press Run.

Tests (Swift Testing, hosted by the app):

```sh
xcodebuild -project Stow.xcodeproj -scheme Stow -derivedDataPath .build test
```

Stow is a regular window app with a Dock icon. Closing the window keeps it running in the
background (checks continue); click the Dock icon to bring it back, and quit with ⌘Q. On first
launch it asks for notification permission and registers itself as a login item for the path it
was launched from; turn that off under Account or with `"launchAtLogin": false` in settings.json.

Debug builds can render every screen to PNGs for review: `Stow --snapshot <dir>`.
The app icon is drawn by `scripts/make-icon.swift`.

## Morning alarm

The **Alarm** section sets it up; everything is also in the `alarm` object of settings.json.

- At the alarm time (default 08:00, Monday to Friday) Stow plays up to 3 new Inbox videos from
  channels marked **Morning**, oldest first, in mpv fullscreen. Videos longer than 60 minutes,
  live streams and premieres are skipped. The alarm never picks a video it already played.
- Three minutes before, it prepares: connects the speaker if needed, checks the feeds, and checks
  each video with yt-dlp (duration, playable). If there is nothing new, the **fallback rules** pick
  one video instead (default: the newest unplayed video from the last 7 days, else replay the newest).
- Sound goes to the speaker (default: the JBL Go 3), else the fallback output ("Mi monitor"),
  else the Mac mini speakers. Stow sets that device's volume (default 80%) right before playing;
  the system output and volume are never changed. While the alarm is on, a near-silent signal keeps
  the Bluetooth speaker from switching itself off, and the Mac is kept from idle sleep (the display may sleep).
- If no video can be streamed (no internet, nothing playable), a built-in alarm sound loops for up to
  10 minutes and a notification explains why. If the Mac wakes more than 10 minutes late, that alarm is skipped.
- Keys while playing: space pauses, `>` skips to the next video, `q` quits. **Stop Alarm** (⌘.) stops everything.
- Played videos leave the Inbox (they move to Recent); videos watched to 90% are remembered for a future phone sync.
- **Test Alarm Now…** runs the whole thing immediately (it is loud).
- While the alarm runs, the paired phone is its remote over the home Wi-Fi: volume, pause, seek, next, another
  video, and I'm Awake. macOS asks once, when Stow opens with a phone paired, whether it may use the local network.

The first time the Alarm section lists Bluetooth devices, macOS asks for Bluetooth permission.

### settings.json `alarm`

Every key is optional; a missing or invalid value falls back to its default. Edits apply without a relaunch.

```json
"alarm" : {
  "enabled" : true,
  "time" : "08:00",
  "days" : [ "mon", "tue", "wed", "thu", "fri" ],
  "maxVideos" : 3,
  "order" : "oldestFirst",
  "volume" : 80,
  "maxDurationMinutes" : 60,
  "fallbackRules" : [
    { "kind" : "mostRecentUnplayed", "channelId" : null, "withinDays" : 7 },
    { "kind" : "replayLatest", "channelId" : null }
  ],
  "speaker" : { "name" : "JBL Go 3", "address" : "40:C1:F6:88:8F:AF", "keepAlive" : true, "keepAliveLevel" : -60 },
  "fallbackOutput" : "Mi monitor"
}
```

| Key | Meaning |
|---|---|
| `time`, `days` | "HH:mm" (24-hour, local); any of mon tue wed thu fri sat sun |
| `maxVideos` | 1–10 new Inbox videos per alarm |
| `order` | `oldestFirst` or `newestFirst` (by publish date) |
| `volume` | 0–100, the output device's own volume |
| `maxDurationMinutes` | 1–600; longer videos are skipped |
| `fallbackRules` | tried in order when nothing new is playable; each yields one video. `kind`: `mostRecentUnplayed`, `randomUnplayed` (both take `withinDays`, 1–365) or `replayLatest`. `channelId` null = any Morning channel |
| `speaker` | the Bluetooth speaker (`address` null = match the output by name only); `keepAliveLevel` in dBFS, −90 to −20 |
| `fallbackOutput` | output name used when the speaker isn't available |

### Alarm dry run

```sh
.build/Build/Products/Debug/Stow.app/Contents/MacOS/Stow --alarm-dryrun
```

Runs the whole alarm headless without any effect (Debug and Release builds): it plans from a
temporary copy of your settings and state, runs prep for real (feed check, yt-dlp with a private
copy of cookies.txt), lists the audio outputs and the one the alarm would use, then streams the
playlist through mpv with no window and no sound for about 20 seconds, printing the player's
events and SponsorBlock segments, and prints the run record it would save. It never changes a
volume, the display, Bluetooth or your files. Exits 0 when a video played.
Paired Bluetooth devices are listed only if the process already has Bluetooth permission.

## Self-test

```sh
.build/Build/Products/Debug/Stow.app/Contents/MacOS/Stow --selftest
```

Runs headless against real YouTube: it resolves @JackhopkinsCEO and @TQQQCRAZY, fetches their
public (RSS) and members-only (yt-dlp) feeds, runs the add/seed/check pipeline in a temporary
directory, prints a summary and exits 0 on success, 1 on failure. When you aren't signed in, the
members-only feed is read with an empty cookie jar. It doesn't write to your settings or state.

## Data

Everything is in `~/Library/Application Support/Stow/`:

| File | Contents |
|---|---|
| `settings.json` | Channels (with `morning` and `phone` toggles), check interval, launch at login, the alarm. Hand-editable; picked up before the next check. |
| `state.json` | Seen video ids per channel, the Inbox, recent videos per channel, the last check result, videos the alarm played or you watched, the last alarm run. |
| `log.json` | The last 500 log entries. |
| `cookies.txt` | YouTube cookies for yt-dlp (mode 0600), exported from Stow's own sign-in window. Deleted on sign-out. |

The sign-in session itself is in a dedicated WebKit data store, separate from Safari.
