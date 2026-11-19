import Foundation

/// One mpv run: reads its IPC events, drives the tracker, overlay and SponsorBlock seeks, and
/// reports `PlayerEvent`s until mpv exits.
actor MPVSession {
    nonisolated let events: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private let process: MPVProcess
    private let socket: MPVSocket
    private var tracker: MPVPlaybackTracker
    private var nextRequestId = 1
    private var playlistPositionRequest: Int?
    private var stopRequested = false
    private var banner: String?
    private var bannerUntil = ContinuousClock.now
    private var helpers: [Task<Void, Never>] = []
    private var runTask: Task<Void, Never>?

    /// Starts mpv and connects to it. Throws `.player` when it can't (mpv is then killed and its files removed).
    static func launch(executable: URL, arguments: [String], socketPath: String, leftovers: [URL],
                       playlist: [PlayableVideo]) async throws -> MPVSession {
        let process = try MPVProcess(executable: executable, arguments: arguments, leftovers: leftovers)
        do {
            let socket = try await MPVSocket.connect(path: socketPath, timeout: .seconds(10)) { process.isRunning }
            let session = MPVSession(process: process, socket: socket, playlist: playlist)
            await session.begin()
            return session
        } catch {
            let exitedEarly = !process.isRunning
            process.finish()
            if exitedEarly { throw StowError.player("mpv exited at once (code \(process.exitCode)).") }
            throw error
        }
    }

    private init(process: MPVProcess, socket: MPVSocket, playlist: [PlayableVideo]) {
        (events, continuation) = AsyncStream.makeStream(of: PlayerEvent.self)
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

    private func begin() {
        let lines = socket.lines()
        send(.requestLogMessages(level: "error"))
        send(.observeProperty(id: 1, name: "time-pos"))
        send(.observeProperty(id: 2, name: "duration"))
        // The first entry's start-file can come before we connected.
        playlistPositionRequest = send(.getProperty("playlist-pos"))
        runTask = Task { await self.run(lines) }
        helpers.append(Task { await self.refreshOverlay() })
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
    }

    private func perform(_ effects: [MPVPlaybackTracker.Effect]) {
        for effect in effects {
            switch effect {
            case .emit(let event):
                continuation.yield(event)
            case .send(let command):
                send(command)
            case .showBanner(let text):
                banner = text
                bannerUntil = .now + OSDOverlay.bannerDuration
                drawOverlay()
                helpers.append(Task {
                    try? await Task.sleep(for: OSDOverlay.bannerDuration)
                    self.drawOverlay()
                })
            }
        }
    }

    private func setSegments(_ segments: [SponsorSegment], videoId: String) {
        tracker.setSegments(segments, videoId: videoId)
    }

    /// Keeps the clock current: redraws at each minute boundary, at least every 15 s.
    private func refreshOverlay() async {
        while !Task.isCancelled {
            drawOverlay()
            let second = Double(Calendar.current.component(.second, from: .now))
            let wait = min(OSDOverlay.refreshInterval, .seconds(max(60 - second, 1)))
            try? await Task.sleep(for: wait)
        }
    }

    private func drawOverlay() {
        if banner != nil, ContinuousClock.now >= bannerUntil { banner = nil }
        send(.osdOverlay(id: OSDOverlay.id, ass: OSDOverlay.text(time: .now, banner: banner), resY: OSDOverlay.resolutionY))
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
