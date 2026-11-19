# Stow for Mac

A Mac app that watches chosen YouTube channels for new long-form and members-only videos
and keeps an Inbox. It stores no videos. Design notes are in [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- macOS 26, Xcode 26
- `brew install xcodegen yt-dlp` (yt-dlp is looked up in /opt/homebrew/bin, /usr/local/bin and /usr/bin)

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
| `settings.json` | Channels (with `morning` and `phone` toggles), check interval, launch at login. Hand-editable; picked up before the next check. |
| `state.json` | Seen video ids per channel, the Inbox, the last check result. |
| `log.json` | The last 500 log entries. |
| `cookies.txt` | YouTube cookies for yt-dlp (mode 0600), exported from Stow's own sign-in window. Deleted on sign-out. |

The sign-in session itself is in a dedicated WebKit data store, separate from Safari.
