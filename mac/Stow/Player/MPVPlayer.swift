import Foundation

/// Fullscreen mpv (child process) driven over its JSON IPC socket: playlist, events and
/// SponsorBlock skipping. mpv only draws the video; Stow's own controls (`PlaybackOverlay`)
/// float over it.
actor MPVPlayer: AlarmPlayer {
    static let format = "bv*[height<=1080][fps<=60]+ba/b"

    /// Appended after the standard options, so they override them (tests: `--vo=null --ao=null --length=…`).
    private let extraArguments: [String]
    /// Whether to show `PlaybackOverlay` over the video (off for tests and the dry run).
    private let showsControls: Bool
    private var session: MPVSession?

    init(extraArguments: [String] = [], showsControls: Bool = false) {
        self.extraArguments = extraArguments
        self.showsControls = showsControls
    }

    func play(playlist: [PlayableVideo], outputDeviceUID: String?, cookiesFile: URL?) async throws -> AsyncStream<PlayerEvent> {
        await stop()
        guard !playlist.isEmpty else { throw StowError.player("Nothing to play.") }
        let mpv = try ToolLocator.url(for: "mpv")
        let ytdlp = try ToolLocator.url(for: "yt-dlp")
        let socketDirectory = try Self.makeSocketDirectory()
        // Without cookies only members-only videos fail, so a failed copy isn't fatal.
        let cookiesCopy = cookiesFile.flatMap { try? CookieCopy.make(of: $0) }
        let socketPath = socketDirectory.appending(path: "mpv.sock").path
        let arguments = Self.arguments(playlist: playlist, socketPath: socketPath, ytdlp: ytdlp,
                                       outputDeviceUID: outputDeviceUID, cookiesCopy: cookiesCopy) + extraArguments
            + ["--"] + playlist.map(\.video.watchURL.absoluteString)
        let session = try await MPVSession.launch(executable: mpv, arguments: arguments, socketPath: socketPath,
                                                  leftovers: [socketDirectory] + (cookiesCopy.map { [$0] } ?? []),
                                                  playlist: playlist)
        self.session = session
        if showsControls {
            await PlaybackOverlay.present(updates: session.nowPlaying) { action in
                Task { await session.perform(action) }
            }
        }
        return session.events
    }

    func stop() async {
        guard let session else { return }
        self.session = nil
        await session.stop()
    }

    /// Kills any mpv this app started, synchronously; called when the app quits.
    static func terminateAll() {
        MPVProcess.terminateAll()
    }

    /// Options before the extra arguments and the URLs.
    static func arguments(playlist: [PlayableVideo], socketPath: String, ytdlp: URL,
                          outputDeviceUID: String?, cookiesCopy: URL?) -> [String] {
        var arguments = [
            "--no-config", "--terminal=no", "--idle=no", "--keep-open=no",
            "--fs", "--native-fs=no", "--ontop", "--force-window=immediate", "--title=Stow Alarm",
            // Stow draws the controls on the first screen (PlaybackOverlay); mpv shows only the video.
            "--screen=0", "--fs-screen=0", "--osc=no", "--osd-level=0", "--osd-bar=no", "--cursor-autohide=always",
            "--volume=100", "--input-ipc-server=\(socketPath)",
            "--script-opts=ytdl_hook-ytdl_path=\(ytdlp.path)", "--ytdl-format=\(format)",
        ]
        if let outputDeviceUID { arguments.append("--audio-device=coreaudio/\(outputDeviceUID)") }
        if let cookiesCopy { arguments.append("--ytdl-raw-options=cookies=\(cookiesCopy.path)") }
        return arguments
    }

    /// A private (0700) folder for the IPC socket; short, because socket paths are limited to 104 bytes.
    private static func makeSocketDirectory() throws -> URL {
        var template = Array((NSTemporaryDirectory() + "stow-mpv.XXXXXX").utf8CString)
        guard let path = mkdtemp(&template) else { throw StowError.player("Couldn't create a socket folder.") }
        return URL(filePath: String(cString: path), directoryHint: .isDirectory)
    }
}
