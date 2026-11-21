import Foundation

/// mpv running inside Stow (libmpv), driven over its JSON IPC socket: playlist, events and
/// SponsorBlock skipping. With controls, the video plays in Stow's alarm window (`AlarmWindow`).
actor MPVPlayer: AlarmPlayer {
    static let format = "bv*[height<=1080][fps<=60]+ba/b"

    /// Appended after the standard options, so they override them (tests: `--vo=null --ao=null --length=…`).
    private let extraArguments: [String]
    /// Whether to play in the alarm window; off (no video output) for tests and the dry run.
    private let showsControls: Bool
    private let mode: PlaybackMode
    private var session: MPVSession?

    init(extraArguments: [String] = [], showsControls: Bool = false, mode: PlaybackMode = .alarm) {
        self.extraArguments = extraArguments
        self.showsControls = showsControls
        self.mode = mode
    }

    func play(playlist: [PlayableVideo], outputDeviceUID: String?, cookiesFile: URL?) async throws -> AsyncStream<PlayerEvent> {
        await stop()
        guard !playlist.isEmpty else { throw StowError.player("Nothing to play.") }
        let ytdlp = try ToolLocator.url(for: "yt-dlp")
        let socketDirectory = try Self.makeSocketDirectory()
        // Without cookies only members-only videos fail, so a failed copy isn't fatal.
        let cookiesCopy = cookiesFile.flatMap { try? CookieCopy.make(of: $0) }
        let socketPath = socketDirectory.appending(path: "mpv.sock").path
        let options = Self.options(socketPath: socketPath, ytdlp: ytdlp, outputDeviceUID: outputDeviceUID,
                                   cookiesCopy: cookiesCopy, drawsVideo: showsControls)
            + extraArguments.compactMap(Self.option(fromArgument:))
        let core = try MPVCore(options: options, leftovers: [socketDirectory] + (cookiesCopy.map { [$0] } ?? []))
        let session = try await MPVSession.launch(process: core, socketPath: socketPath, playlist: playlist)
        self.session = session
        do {
            // The window's video output has to exist before the first video starts.
            if showsControls {
                try await AlarmWindow.present(core: core, updates: session.nowPlaying, mode: mode) { action in
                    Task { await session.perform(action) }
                }
            }
            guard core.load(playlist.map(\.video.watchURL)) else { throw StowError.player("mpv refused the playlist.") }
        } catch {
            await stop()
            throw error
        }
        return session.events
    }

    func stop() async {
        guard let session else { return }
        self.session = nil
        await session.stop()
    }

    func nowPlaying() async -> NowPlaying? {
        await session?.latestNowPlaying
    }

    func perform(_ action: PlaybackAction) async {
        await session?.perform(action)
    }

    /// Shuts down any mpv this app started, synchronously; called when the app quits.
    static func terminateAll() {
        MPVCore.terminateAll()
    }

    /// mpv options before the extra arguments. `drawsVideo` renders into Stow's alarm window;
    /// otherwise there is no video output at all.
    static func options(socketPath: String, ytdlp: URL, outputDeviceUID: String?, cookiesCopy: URL?,
                        drawsVideo: Bool) -> [(String, String)] {
        var options = [
            ("config", "no"), ("terminal", "no"), ("idle", "once"), ("keep-open", "no"),
            ("vo", drawsVideo ? "libmpv" : "null"), ("hwdec", "auto-safe"),
            // Stow's window handles every key and click; mpv draws no controls or messages.
            ("input-default-bindings", "no"), ("input-vo-keyboard", "no"), ("osc", "no"), ("osd-level", "0"),
            ("volume", "100"), ("input-ipc-server", socketPath),
            ("ytdl", "yes"), ("script-opts", "ytdl_hook-ytdl_path=\(ytdlp.path)"), ("ytdl-format", format),
        ]
        if let outputDeviceUID { options.append(("audio-device", "coreaudio/\(outputDeviceUID)")) }
        if let cookiesCopy { options.append(("ytdl-raw-options", "cookies=\(cookiesCopy.path)")) }
        return options
    }

    /// "--name=value" → (name, value); "--name" → (name, "yes"); "--no-name" → (name, "no").
    static func option(fromArgument argument: String) -> (String, String)? {
        guard argument.hasPrefix("--"), argument.count > 2 else { return nil }
        let body = argument.dropFirst(2)
        if let equals = body.firstIndex(of: "=") {
            return (String(body[..<equals]), String(body[body.index(after: equals)...]))
        }
        if body.hasPrefix("no-") { return (String(body.dropFirst(3)), "no") }
        return (String(body), "yes")
    }

    /// A private (0700) folder for the IPC socket; short, because socket paths are limited to 104 bytes.
    private static func makeSocketDirectory() throws -> URL {
        var template = Array((NSTemporaryDirectory() + "stow-mpv.XXXXXX").utf8CString)
        guard let path = mkdtemp(&template) else { throw StowError.player("Couldn't create a socket folder.") }
        return URL(filePath: String(cString: path), directoryHint: .isDirectory)
    }
}
