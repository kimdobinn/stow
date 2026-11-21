import Foundation

// Alarm module boundaries. FROZEN: request changes from the architect.
// Core/Alarm depends only on these protocols; StowApp wires up the concrete types:
//   MPVPlayer (Player), AlarmSound (Player), CoreAudioOutputs, BluetoothSpeaker, KeepAlive,
//   PowerAssertions (System), YTDLPVideoDetails (YouTube), AlarmRemote (Remote).

/// Plays the morning videos fullscreen in mpv, streamed from YouTube. Implemented by Player/MPVPlayer.
protocol AlarmPlayer: Sendable {
    /// Starts mpv on `playlist` (in order) with audio on `outputDeviceUID` (nil = system default)
    /// and returns its events; the stream ends after `.exited`. `cookiesFile` is the real
    /// cookies.txt (nil when signed out): the player gives mpv/yt-dlp a private copy
    /// (`CookieCopy.make`) and deletes it when mpv exits. Skips SponsorBlock segments and draws
    /// the clock/title overlay itself. Calling it while playing stops the previous run first.
    /// Throws `.toolNotFound` or `.player` when mpv can't be started.
    func play(playlist: [PlayableVideo], outputDeviceUID: String?, cookiesFile: URL?) async throws -> AsyncStream<PlayerEvent>

    /// Quits mpv; the event stream then yields `.exited(.stopped)`. No-op when idle.
    func stop() async

    /// What the running playlist shows (the window's view); nil when mpv isn't running.
    func nowPlaying() async -> NowPlaying?

    /// Carries out a control request (from the window or the phone) on the running playlist.
    /// `.playVideo` of a new video yields `.appended` before it starts. No-op when idle.
    func perform(_ action: PlaybackAction) async
}

/// Lets the paired phone see and control a running alarm over the local network.
/// Implemented by Remote/AlarmRemote.
@MainActor
protocol AlarmRemoteService: AnyObject {
    /// Called with every phase of a run, from `.preparing` to `.idle` (the run ended).
    func alarmPhaseChanged(_ phase: AlarmPhase, run: any AlarmRunControl)
}

/// A running alarm as the phone remote drives it. Implemented by Core/Alarm (AlarmController).
@MainActor
protocol AlarmRunControl: AnyObject {
    var phase: AlarmPhase { get }
    func runStatus() async -> AlarmRunStatus
    /// Inbox and recent videos (any order, may repeat), for switching to another video.
    var knownVideos: [Video] { get }
    /// A player request; ignored unless the player is running.
    func perform(_ action: PlaybackAction) async
    /// Sets the alarm output's own volume (0–100). Before the output is chosen, the run uses it
    /// instead of the configured volume. The previous volume still comes back when the run ends.
    func setOutputVolume(_ volume: Int)
    /// Stop Alarm: cancels prep, stops mpv and the alarm sound.
    func stop()
    /// A best-effort FCM data message to every paired phone; returns at once.
    func pushToPhones(_ data: [String: String])
    func log(_ level: LogLevel, _ message: String)
}

/// Loops a built-in alarm sound (/System/Library/Sounds/Glass.aiff) on a specific output.
/// Implemented by Player/AlarmSound. Plays at full player volume; the caller sets the device volume.
@MainActor
protocol AlarmSoundPlayer: AnyObject {
    var isPlaying: Bool { get }
    /// Loops the sound on `deviceUID` (nil = system default) and returns after `duration` or
    /// when `stop()` is called. Throws `.audio` / `.audioDeviceNotFound` when it can't play.
    func play(deviceUID: String?, duration: Duration) async throws
    func stop()
}

/// CoreAudio output devices. Implemented by System/CoreAudioOutputs.
protocol AudioOutputService: Sendable {
    /// Every device with output channels, in CoreAudio order.
    func outputs() -> [AudioOutput]
    /// Output volume 0…1 (main or virtual main volume); nil when the device has no volume control.
    func volume(deviceUID: String) -> Double?
    /// Sets the device's own output volume (never the system default device or system volume).
    /// Throws `.audioDeviceNotFound`, `.audio`.
    func setVolume(_ volume: Double, deviceUID: String) throws
    /// Yields whenever devices appear or disappear (e.g. the speaker connects). Never finishes on its own.
    func changes() -> AsyncStream<Void>
}

/// Paired Bluetooth speakers. Implemented by System/BluetoothSpeaker. Read-only except `connect`.
@MainActor
protocol SpeakerService: AnyObject {
    /// Paired devices whose class says they play audio, sorted by name.
    func pairedAudioDevices() -> [BluetoothAudioDevice]
    /// `address` in any common form ("40:C1:…" / "40-c1-…").
    func isConnected(address: String) -> Bool
    /// Opens a connection to a paired device; returns whether it is connected within `timeout`.
    /// Returns at once when it already is.
    func connect(address: String, timeout: Duration) async -> Bool
    /// Yields when any Bluetooth device connects or disconnects. Never finishes on its own.
    func changes() -> AsyncStream<Void>
}

/// A near-silent continuous signal on one output so a speaker doesn't auto-power-off.
/// Implemented by System/KeepAlive (AVAudioEngine bound to that device, not the default output).
@MainActor
protocol KeepAliveService: AnyObject {
    var isRunning: Bool { get }
    /// The device it is playing on, while running.
    var deviceUID: String? { get }
    /// Starts (or moves to `deviceUID` / changes level). `levelDBFS` is clamped to
    /// `SpeakerSettings.keepAliveLevelRange`. Throws `.audioDeviceNotFound`, `.audio`.
    func start(deviceUID: String, levelDBFS: Double) throws
    /// Stops it; also stops by itself (isRunning becomes false) when the device disappears.
    func stop()
    /// Plays the signal at `levelDBFS` for `duration` so the user can judge it, then restores
    /// whatever was running before.
    func test(deviceUID: String, levelDBFS: Double, duration: Duration) async throws
}

/// Implemented by System/PowerAssertions.
@MainActor
protocol PowerService: AnyObject {
    var isHoldingSystemAwake: Bool { get }
    /// Holds (or releases) an IOPMAssertion preventing idle system sleep; the display may sleep.
    /// Idempotent.
    func holdSystemAwake(_ on: Bool)
    /// Wakes the display (IOPMAssertionDeclareUserActivity, kIOPMUserActiveLocal).
    func wakeDisplay()
}

struct VideoDetails: Equatable, Sendable {
    var id: String
    var duration: TimeInterval?
    var liveStatus: LiveStatus
    /// yt-dlp resolved the video (with cookies when given), so mpv should be able to stream it.
    var isPlayable: Bool
    /// Why it isn't playable.
    var error: String?
}

/// Implemented by YouTube/VideoDetails (YTDLPVideoDetails): `yt-dlp -J --no-playlist` per video.
protocol VideoDetailsService: Sendable {
    /// Details for every id (at most 3 yt-dlp runs at a time, each with a timeout). Never throws:
    /// a failure gives `isPlayable == false` with `error`. `cookiesFile` is the real cookies.txt;
    /// each run gets a private copy (`CookieCopy.make`).
    func details(for ids: [String], cookiesFile: URL?) async -> [String: VideoDetails]
}

/// Every alarm dependency, passed to `AppModel` by `StowApp` (tests and previews use
/// `AlarmServices.inert`, defined in Core/Alarm).
@MainActor
struct AlarmServices {
    var player: any AlarmPlayer
    var sound: any AlarmSoundPlayer
    var outputs: any AudioOutputService
    var speaker: any SpeakerService
    var keepAlive: any KeepAliveService
    var power: any PowerService
    var videoDetails: any VideoDetailsService
    var remote: any AlarmRemoteService
}

/// What the alarm needs from the app's model. Implemented by `AppModel` (Core/AppModel.swift).
@MainActor
protocol AlarmHost: AnyObject {
    /// Settings, re-read first if settings.json was edited by hand.
    func currentSettings() -> AppSettings
    var currentState: AppState { get }
    /// The real cookies.txt unless signed out or missing; pass it on to the player and yt-dlp,
    /// which make private copies.
    var playbackCookiesFile: URL? { get }
    /// Runs a feed check (trigger `.alarm`) and returns once it, and any check already running,
    /// has finished, so the Inbox and recent videos are fresh.
    func refreshForAlarm() async
    /// Saves `run` as `lastAlarmRun`, adds `run.videoIds` to `alarmPlayedIds` and `watchedIds` to
    /// `watchedIds`, and moves `run.videoIds` out of the Inbox (into Recent). A test run does that
    /// only for `watchedIds`. Call it again as the run progresses; ids are merged, not duplicated.
    /// Doesn't log.
    func recordAlarmRun(_ run: AlarmRunRecord, watchedIds: [String])
    func logAlarm(_ level: LogLevel, _ message: String)
    /// Rate-limited per title, like other problem notifications.
    func notifyAlarmProblem(title: String, body: String)
    /// A best-effort FCM data message to every paired phone (the alarm remote's start and end).
    /// Returns at once; failures are only logged.
    func pushToPhones(_ data: [String: String])
}
