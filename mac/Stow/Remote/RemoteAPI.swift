import CryptoKit
import Foundation

// The phone remote's HTTP API (shared contract with android/): GET /v1/state, GET /v1/choices,
// POST /v1/action. Field names here are the contract; the Android app decodes exactly these.

/// A video as the phone shows it.
struct RemoteVideo: Encodable, Equatable {
    var id: String
    var title: String
    var channelTitle: String
    var thumbnailURL: String
    /// Only in /v1/choices.
    var publishedAt: Date??

    init(_ video: Video, withDate: Bool = false) {
        id = video.id
        title = video.title
        channelTitle = video.channelTitle
        thumbnailURL = "https://i.ytimg.com/vi/\(video.id)/hqdefault.jpg"
        publishedAt = withDate ? .some(video.publishedAt) : .none
    }

    private enum CodingKeys: String, CodingKey { case id, title, channelTitle, thumbnailURL, publishedAt }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(channelTitle, forKey: .channelTitle)
        try container.encode(thumbnailURL, forKey: .thumbnailURL)
        if case .some(let date) = publishedAt {
            try container.encode(date.map { $0.formatted(.iso8601) }, forKey: .publishedAt)
        }
    }
}

/// GET /v1/state, and the answer to every action.
struct RemoteState: Encodable, Equatable {
    var active: Bool
    var phase: String
    var macName: String
    var index: Int
    var count: Int
    var video: RemoteVideo?
    var isLoading: Bool
    var isPaused: Bool
    var position: Double
    var duration: Double?
    var volume: Int?
    var outputName: String?
    var isMuted: Bool
    var playlist: [RemoteVideo]

    init(_ status: AlarmRunStatus, macName: String) {
        let playing = status.nowPlaying
        active = status.phase.isActive
        phase = switch status.phase {
        case .idle: "ended"
        case .preparing: "preparing"
        case .starting: "starting"
        case .playing: "playing"
        case .alarmSound: "alarmSound"
        }
        self.macName = macName
        index = playing?.index ?? 0
        count = playing?.count ?? 0
        video = playing.map { RemoteVideo($0.video) }
        // Waiting for mpv's first video counts as loading.
        let starting = if case .starting = status.phase { true } else { false }
        isLoading = playing?.isLoading ?? starting
        isPaused = playing?.isPaused ?? false
        position = playing?.position ?? 0
        duration = playing?.duration
        volume = status.volume
        outputName = status.outputName
        isMuted = playing?.isMuted ?? false
        playlist = status.playlist.map { RemoteVideo($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case active, phase, macName, index, count, video, isLoading, isPaused, position, duration, volume, outputName,
             isMuted, playlist
    }

    /// Absent values are written as null, never left out.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(active, forKey: .active)
        try container.encode(phase, forKey: .phase)
        try container.encode(macName, forKey: .macName)
        try container.encode(index, forKey: .index)
        try container.encode(count, forKey: .count)
        try container.encode(video, forKey: .video)
        try container.encode(isLoading, forKey: .isLoading)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(position, forKey: .position)
        try container.encode(duration, forKey: .duration)
        try container.encode(volume, forKey: .volume)
        try container.encode(outputName, forKey: .outputName)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(playlist, forKey: .playlist)
    }
}

/// GET /v1/choices: videos the phone can switch to.
struct RemoteChoices: Encodable, Equatable {
    static let limit = 40

    var videos: [RemoteVideo]

    /// De-duplicated, without live or upcoming videos, newest first (undated last), at most `limit`.
    init(from known: [Video]) {
        var seen = Set<String>()
        let unique = known.filter { $0.liveStatus != .live && $0.liveStatus != .upcoming && seen.insert($0.id).inserted }
        let sorted = unique.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element.publishedAt ?? .distantPast, rhs.element.publishedAt ?? .distantPast)
            return a != b ? a > b : lhs.offset < rhs.offset
        }
        videos = sorted.prefix(Self.limit).map { RemoteVideo($0.element, withDate: true) }
    }
}

/// A POST /v1/action body.
enum RemoteAction: Equatable {
    case setPaused(Bool)
    case seekBy(Double)
    case seekTo(Double)
    case next
    case playIndex(Int)
    case playVideo(String)
    case setVolume(Int)
    case setMuted(Bool)
    case stop

    /// What carrying out an action means for the run.
    enum Effect: Equatable {
        case player(PlaybackAction)
        case outputVolume(Int)
        case stop
    }

    private struct Body: Decodable {
        var action: String
        var paused: Bool?
        var seconds: Double?
        var index: Int?
        var videoId: String?
        var volume: Double?
        var muted: Bool?
    }

    /// Throws a message for a 400 when the body isn't a valid action.
    static func decode(_ data: Data) throws(RemoteRequestError) -> RemoteAction {
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw .badRequest("The body must be a JSON object with an \"action\" and its fields.")
        }
        func required<T>(_ value: T?, _ name: String) throws(RemoteRequestError) -> T {
            guard let value else { throw .badRequest("\"\(body.action)\" needs \"\(name)\".") }
            return value
        }
        func seconds() throws(RemoteRequestError) -> Double {
            let value = try required(body.seconds, "seconds")
            guard value.isFinite else { throw .badRequest("\"seconds\" must be a number.") }
            return value
        }
        switch body.action {
        case "setPaused": return .setPaused(try required(body.paused, "paused"))
        case "seekBy": return .seekBy(try seconds())
        case "seekTo":
            let value = try seconds()
            guard value >= 0 else { throw .badRequest("\"seconds\" can't be negative.") }
            return .seekTo(value)
        case "next": return .next
        case "playIndex":
            let index = try required(body.index, "index")
            guard index >= 0 else { throw .badRequest("\"index\" can't be negative.") }
            return .playIndex(index)
        case "playVideo":
            let id = try required(body.videoId, "videoId")
            guard !id.isEmpty else { throw .badRequest("\"videoId\" is empty.") }
            return .playVideo(id)
        case "setVolume":
            let volume = try required(body.volume, "volume")
            guard volume.isFinite else { throw .badRequest("\"volume\" must be a number.") }
            return .setVolume(Int(min(max(volume, 0), 100).rounded()))
        case "setMuted": return .setMuted(try required(body.muted, "muted"))
        case "stop": return .stop
        default: throw .badRequest("Unknown action \"\(body.action)\".")
        }
    }

    /// What the action does in `status`; throws 409 when it doesn't apply now, 400 when it
    /// names a video or entry that doesn't exist. `known` are the videos the phone may pick.
    func effect(in status: AlarmRunStatus, known: [Video]) throws(RemoteRequestError) -> Effect {
        func requirePlayer() throws(RemoteRequestError) {
            guard status.nowPlaying == nil else { return }
            throw .conflict(status.phase.isActive ? "Nothing is playing yet." : "The alarm has ended.")
        }
        func player(_ action: PlaybackAction) throws(RemoteRequestError) -> Effect {
            try requirePlayer()
            return .player(action)
        }
        switch self {
        case .stop: return .stop
        case .setVolume(let volume):
            guard status.phase.isActive else { throw .conflict("The alarm has ended.") }
            return .outputVolume(volume)
        case .setPaused(let paused): return try player(.setPaused(paused))
        case .seekBy(let seconds): return try player(.seekBy(seconds))
        case .seekTo(let seconds): return try player(.seekTo(seconds))
        case .next: return try player(.next)
        case .setMuted(let muted): return try player(.setMuted(muted))
        case .playIndex(let index):
            try requirePlayer()
            guard status.playlist.indices.contains(index) else {
                throw .badRequest("There is no entry \(index) (the playlist has \(status.playlist.count)).")
            }
            return .player(.playIndex(index))
        case .playVideo(let id):
            try requirePlayer()
            if let index = status.playlist.firstIndex(where: { $0.id == id }) { return try player(.playIndex(index)) }
            guard let video = known.first(where: { $0.id == id }), video.liveStatus != .live, video.liveStatus != .upcoming else {
                throw .badRequest("Unknown or live video \(id).")
            }
            return try player(.playVideo(PlayableVideo(video: video, duration: nil)))
        }
    }
}

enum RemoteRequestError: Error, Equatable {
    case badRequest(String)
    case conflict(String)

    var response: RemoteHTTPResponse {
        switch self {
        case .badRequest(let message): .error(.badRequest, message)
        case .conflict(let message): .error(.conflict, message)
        }
    }
}

/// Answers one alarm run's requests: checks each signature, then serves the run's state, the
/// videos to switch to, and actions.
@MainActor
final class RemoteAPI {
    /// After a player action, mpv's events (pause, position) arrive within this; the answer waits for them.
    static let playerSettle: Duration = .milliseconds(250)
    /// After "stop", the answer waits up to this for the run to end, so it can say so.
    static let stopSettle: Duration = .seconds(3)

    private weak var run: (any AlarmRunControl)?
    private let key: SymmetricKey
    private let macName: String
    private let now: () -> Date
    private let nonces: RemoteNonceStore
    /// False once this API's run is over: `run` is the controller, which may already be running the next one.
    private let isCurrent: () -> Bool
    private var loggedAuthFailure = false
    /// Every request and its answer, for `Stow --remote-demo`.
    var trace: ((String) -> Void)?

    init(run: any AlarmRunControl, key: SymmetricKey, macName: String, nonces: RemoteNonceStore = RemoteNonceStore(),
         isCurrent: @escaping () -> Bool = { true }, now: @escaping () -> Date = { .now }) {
        self.run = run
        self.key = key
        self.macName = macName
        self.nonces = nonces
        self.isCurrent = isCurrent
        self.now = now
    }

    func handle(_ request: RemoteHTTPRequest) async -> RemoteHTTPResponse {
        let response = await answer(request)
        trace?("\(request.method) \(request.path) → \(response.status.rawValue) \(String(decoding: response.body, as: UTF8.self))")
        return response
    }

    private func answer(_ request: RemoteHTTPRequest) async -> RemoteHTTPResponse {
        if let failure = RemoteAuth.failure(of: request, key: key, now: now(), nonces: &nonces.cache) {
            // Once per run: a phone with a wrong key or clock would otherwise fill the Log.
            if !loggedAuthFailure {
                loggedAuthFailure = true
                run?.log(.warning, "Phone remote: rejected a request: \(failure)")
            }
            return .error(.unauthorized, failure)
        }
        let routes = ["/v1/state": "GET", "/v1/choices": "GET", "/v1/action": "POST"]
        guard let method = routes[request.path] else { return .error(.notFound, "No such endpoint.") }
        guard request.method == method else { return .error(.methodNotAllowed, "\(request.path) takes \(method).") }
        switch request.path {
        case "/v1/choices":
            return .json(RemoteChoices(from: run?.knownVideos ?? []))
        case "/v1/action":
            return await act(on: request.body)
        default:
            return .json(await state())
        }
    }

    private func state() async -> RemoteState {
        RemoteState(await run?.runStatus() ?? .ended, macName: macName)
    }

    private func act(on body: Data) async -> RemoteHTTPResponse {
        do throws(RemoteRequestError) {
            let action = try RemoteAction.decode(body)
            guard let run else { throw .conflict("The alarm has ended.") }
            let effect = try action.effect(in: await run.runStatus(), known: run.knownVideos)
            guard isCurrent() else { throw .conflict("The alarm has ended.") }
            trace?("action \(action) → \(effect)")
            switch effect {
            case .player(let playback):
                run.log(.info, "Phone remote: \(Self.describe(playback)).")
                await run.perform(playback)
                try? await Task.sleep(for: Self.playerSettle)
            case .outputVolume(let volume):
                run.log(.info, "Phone remote: volume \(volume)%.")
                run.setOutputVolume(volume)
            case .stop:
                run.log(.info, "Phone remote: I'm awake.")
                run.stop()
                let deadline = ContinuousClock.now + Self.stopSettle
                while run.phase.isActive, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            return .json(await state())
        } catch {
            return error.response
        }
    }

    private static func describe(_ action: PlaybackAction) -> String {
        switch action {
        case .setPaused(let paused): paused ? "pause" : "play"
        case .seekBy(let seconds): "seek \(seconds >= 0 ? "+" : "")\(Int(seconds)) s"
        case .seekTo(let seconds): "seek to \(Int(seconds)) s"
        case .next: "next video"
        case .playIndex(let index): "play video \(index + 1)"
        case .playVideo(let video): "play “\(video.video.title)” (\(video.video.id))"
        case .setVolume(let volume): "player volume \(Int(volume))%"
        case .setMuted(let muted): muted ? "mute" : "unmute"
        case .stop: "stop"
        }
    }
}
