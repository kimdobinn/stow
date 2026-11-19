import Foundation

/// One mpv run: reads its IPC events, drives the tracker and SponsorBlock seeks, and reports
/// `PlayerEvent`s (and `NowPlaying` for the on-screen controls) until mpv exits.
actor MPVSession {
    nonisolated let events: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    /// Every change of what the controls show; ends when mpv exits.
    nonisolated let nowPlaying: AsyncStream<NowPlaying>
    private let nowPlayingContinuation: AsyncStream<NowPlaying>.Continuation
    private var lastNowPlaying: NowPlaying?
    private let process: MPVCore
    private let socket: MPVSocket
    private var tracker: MPVPlaybackTracker
    private var nextRequestId = 1
    private var playlistPositionRequest: Int?
    private var stopRequested = false
    private var helpers: [Task<Void, Never>] = []
    private var runTask: Task<Void, Never>?

    /// Connects to the running `process` (its IPC socket at `socketPath`). Throws `.player` when it
    /// can't (the core is then shut down and its files removed).
    static func launch(process: MPVCore, socketPath: String, playlist: [PlayableVideo]) async throws -> MPVSession {
        do {
            let socket = try await MPVSocket.connect(path: socketPath, timeout: .seconds(10)) { process.isRunning }
            let session = MPVSession(process: process, socket: socket, playlist: playlist)
            await session.begin()
            return session
        } catch {
            let exitedEarly = !process.isRunning
            process.finish()
            if exitedEarly { throw StowError.player("mpv stopped at once.") }
            throw error
        }
    }

    private init(process: MPVCore, socket: MPVSocket, playlist: [PlayableVideo]) {
        (events, continuation) = AsyncStream.makeStream(of: PlayerEvent.self)
        (nowPlaying, nowPlayingContinuation) = AsyncStream.makeStream(of: NowPlaying.self,
                                                                      bufferingPolicy: .bufferingNewest(1))
        self.process = process
        self.socket = socket
        tracker = MPVPlaybackTracker(playlist: playlist)
    }

    /// Asks mpv to quit; terminates it after 2 s, kills it after 2 more. Returns once `.exited` was sent.
    func stop() async {
        stopRequested = true
        send(.quit)
        if await !process.waitForExit(timeout: .seconds(2)) {
            process.terminate()
            if await !process.waitForExit(timeout: .seconds(2)) { process.kill() }
        }
        await runTask?.value
    }

    /// Carries out a request from the on-screen controls.
    func perform(_ action: PlaybackAction) async {
        switch action {
        case .setPaused(let paused): send(.setPause(paused))
        case .seekBy(let seconds): send(.seekRelative(seconds))
        case .seekTo(let seconds): send(.seekAbsolute(max(seconds, 0)))
        case .next: send(.playlistNext)
        case .setVolume(let volume): send(.setVolume(min(max(volume, 0), 100).rounded()))
        case .setMuted(let muted): send(.setMute(muted))
        case .stop: await stop()
        }
    }

    private func begin() {
        let lines = socket.lines()
        send(.requestLogMessages(level: "error"))
        send(.observeProperty(id: 1, name: "time-pos"))
        send(.observeProperty(id: 2, name: "duration"))
        send(.observeProperty(id: 3, name: "pause"))
        send(.observeProperty(id: 4, name: "volume"))
        send(.observeProperty(id: 5, name: "mute"))
        // The first entry's start-file can come before we connected.
        playlistPositionRequest = send(.getProperty("playlist-pos"))
        runTask = Task { await self.run(lines) }
        publishNowPlaying()
        for id in Set(tracker.playlist.map(\.video.id)) {
            helpers.append(Task {
                let segments = await SponsorBlock.segments(videoId: id)
                self.setSegments(segments, videoId: id)
            })
        }
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            Task { await self.stop() }
        }
    }

    private func run(_ lines: AsyncStream<Data>) async {
        for await line in lines {
            guard let message = MPVIPC.parse(line) else { continue }
            receive(message)
        }
        // The socket closes when mpv exits; if mpv is somehow still there, it's out of our control.
        let lostConnection = await !process.waitForExit(timeout: .seconds(2))
        process.finish()
        helpers.forEach { $0.cancel() }
        let exit = lostConnection && !stopRequested
            ? .failed("Lost the connection to mpv.")
            : tracker.exit(stopRequested: stopRequested, exitCode: process.exitCode)
        continuation.yield(.exited(exit))
        continuation.finish()
        nowPlayingContinuation.finish()
    }

    private func receive(_ message: MPVMessage) {
        switch message {
        case .reply(let requestId, _, let position):
            if requestId == playlistPositionRequest, tracker.currentIndex == nil, let position, position >= 0 {
                perform(tracker.handle(.startFile(entryId: Int(position) + 1)))
            }
        case .event(let event):
            perform(tracker.handle(event))
        }
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        let current = tracker.nowPlaying
        guard current != lastNowPlaying else { return }
        lastNowPlaying = current
        nowPlayingContinuation.yield(current)
    }

    private func perform(_ effects: [MPVPlaybackTracker.Effect]) {
        for effect in effects {
            switch effect {
            case .emit(let event):
                continuation.yield(event)
            case .send(let command):
                send(command)
            }
        }
    }

    private func setSegments(_ segments: [SponsorSegment], videoId: String) {
        tracker.setSegments(segments, videoId: videoId)
    }

    /// Fire-and-forget; a failed write means mpv is exiting, which `run` reports.
    @discardableResult
    private func send(_ command: MPVCommand) -> Int {
        let id = nextRequestId
        nextRequestId += 1
        try? socket.send(MPVIPC.encode(command, requestId: id))
        return id
    }
}
