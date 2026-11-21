import Foundation
import Testing
@testable import Stow

/// A run the remote can drive, recording what it was asked to do.
@MainActor
final class FakeRunControl: AlarmRunControl {
    var status: AlarmRunStatus
    var knownVideos: [Video] = []
    var performed: [PlaybackAction] = []
    var volumes: [Int] = []
    var stops = 0
    var pushes: [[String: String]] = []
    var logs: [String] = []

    init(_ status: AlarmRunStatus) { self.status = status }

    var phase: AlarmPhase { status.phase }
    func runStatus() async -> AlarmRunStatus { status }
    func perform(_ action: PlaybackAction) async { performed.append(action) }
    func setOutputVolume(_ volume: Int) { volumes.append(volume) }
    func stop() {
        stops += 1
        status = .ended
    }
    func pushToPhones(_ data: [String: String]) { pushes.append(data) }
    func log(_ level: LogLevel, _ message: String) { logs.append(message) }
}

func playingStatus(index: Int = 0, ids: [String] = ["a", "b"]) -> AlarmRunStatus {
    let videos = ids.map { video($0) }
    return AlarmRunStatus(phase: .playing(index: index, count: videos.count, video: videos[index]), playlist: videos,
                          nowPlaying: NowPlaying(index: index, count: videos.count, video: videos[index], isLoading: false,
                                                 isPaused: true, position: 12, duration: 600, upNext: nil,
                                                 volume: 100, isMuted: true),
                          outputName: "JBL Go 3", volume: 40)
}

struct RemoteActionTests {
    private func decode(_ json: String) throws -> RemoteAction {
        try RemoteAction.decode(Data(json.utf8))
    }

    @Test func decodesEveryAction() throws {
        #expect(try decode(#"{"action":"setPaused","paused":true}"#) == .setPaused(true))
        #expect(try decode(#"{"action":"seekBy","seconds":-10}"#) == .seekBy(-10))
        #expect(try decode(#"{"action":"seekTo","seconds":120.5}"#) == .seekTo(120.5))
        #expect(try decode(#"{"action":"next"}"#) == .next)
        #expect(try decode(#"{"action":"playIndex","index":2}"#) == .playIndex(2))
        #expect(try decode(#"{"action":"playVideo","videoId":"abc"}"#) == .playVideo("abc"))
        #expect(try decode(#"{"action":"setVolume","volume":55}"#) == .setVolume(55))
        #expect(try decode(#"{"action":"setMuted","muted":false}"#) == .setMuted(false))
        #expect(try decode(#"{"action":"stop","extra":1}"#) == .stop)
    }

    @Test func clampsTheVolume() throws {
        #expect(try decode(#"{"action":"setVolume","volume":150}"#) == .setVolume(100))
        #expect(try decode(#"{"action":"setVolume","volume":-5}"#) == .setVolume(0))
        #expect(try decode(#"{"action":"setVolume","volume":55.6}"#) == .setVolume(56))
    }

    @Test func rejectsBadBodies() {
        for body in ["", "[]", "not json", #"{"paused":true}"#, #"{"action":"jump"}"#, #"{"action":"setPaused"}"#,
                     #"{"action":"setPaused","paused":1}"#, #"{"action":"seekTo","seconds":-1}"#,
                     #"{"action":"seekBy","seconds":"10"}"#, #"{"action":"playIndex","index":-1}"#,
                     #"{"action":"playIndex","index":1.5}"#, #"{"action":"playVideo","videoId":""}"#,
                     #"{"action":"setVolume"}"#] {
            #expect(throws: RemoteRequestError.self, "\(body)") { try decode(body) }
        }
    }

    @Test func onlyStopAndVolumeApplyBeforeVideosPlay() throws {
        let preparing = AlarmRunStatus(phase: .preparing(scheduledFor: .now), playlist: [], nowPlaying: nil,
                                       outputName: nil, volume: nil)
        #expect(try RemoteAction.stop.effect(in: preparing, known: []) == .stop)
        #expect(try RemoteAction.setVolume(30).effect(in: preparing, known: []) == .outputVolume(30))
        for action in [RemoteAction.setPaused(true), .seekBy(10), .seekTo(0), .next, .playIndex(0), .playVideo("a"), .setMuted(true)] {
            #expect(throws: RemoteRequestError.conflict("Nothing is playing yet.")) { try action.effect(in: preparing, known: []) }
        }
        let sound = AlarmRunStatus(phase: .alarmSound(reason: "offline"), playlist: [], nowPlaying: nil, outputName: "JBL Go 3", volume: 80)
        #expect(throws: RemoteRequestError.self) { try RemoteAction.next.effect(in: sound, known: []) }
        #expect(throws: RemoteRequestError.conflict("The alarm has ended.")) { try RemoteAction.setVolume(5).effect(in: .ended, known: []) }
        #expect(try RemoteAction.stop.effect(in: .ended, known: []) == .stop)
    }

    @Test func mapsPlayerActionsWhilePlaying() throws {
        let status = playingStatus()
        #expect(try RemoteAction.setPaused(false).effect(in: status, known: []) == .player(.setPaused(false)))
        #expect(try RemoteAction.seekBy(-10).effect(in: status, known: []) == .player(.seekBy(-10)))
        #expect(try RemoteAction.next.effect(in: status, known: []) == .player(.next))
        #expect(try RemoteAction.playIndex(1).effect(in: status, known: []) == .player(.playIndex(1)))
        #expect(throws: RemoteRequestError.self) { try RemoteAction.playIndex(2).effect(in: status, known: []) }
    }

    @Test func playVideoJumpsToAPlaylistEntryOrAddsAKnownVideo() throws {
        let status = playingStatus()
        let known = [video("c"), video("live", live: .live)]
        #expect(try RemoteAction.playVideo("b").effect(in: status, known: known) == .player(.playIndex(1)))
        #expect(try RemoteAction.playVideo("c").effect(in: status, known: known)
                == .player(.playVideo(PlayableVideo(video: video("c"), duration: nil))))
        #expect(throws: RemoteRequestError.self) { try RemoteAction.playVideo("zzz").effect(in: status, known: known) }
        #expect(throws: RemoteRequestError.self) { try RemoteAction.playVideo("live").effect(in: status, known: known) }
    }
}

struct RemoteJSONTests {
    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = RemoteHTTPResponse.json(value).body
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func stateHasExactlyTheContractFields() throws {
        let json = try object(RemoteState(playingStatus(index: 1), macName: "Kim's Mac mini"))
        #expect(Set(json.keys) == ["active", "phase", "macName", "index", "count", "video", "isLoading", "isPaused",
                                   "position", "duration", "volume", "outputName", "isMuted", "playlist"])
        #expect(json["active"] as? Bool == true)
        #expect(json["phase"] as? String == "playing")
        #expect(json["macName"] as? String == "Kim's Mac mini")
        #expect(json["index"] as? Int == 1 && json["count"] as? Int == 2)
        #expect(json["isLoading"] as? Bool == false && json["isPaused"] as? Bool == true && json["isMuted"] as? Bool == true)
        #expect(json["position"] as? Double == 12 && json["duration"] as? Double == 600)
        #expect(json["volume"] as? Int == 40 && json["outputName"] as? String == "JBL Go 3")
        let video = try #require(json["video"] as? [String: Any])
        #expect(Set(video.keys) == ["id", "title", "channelTitle", "thumbnailURL"])
        #expect(video["id"] as? String == "b")
        #expect(video["thumbnailURL"] as? String == "https://i.ytimg.com/vi/b/hqdefault.jpg")
        let playlist = try #require(json["playlist"] as? [[String: Any]])
        #expect(playlist.map { $0["id"] as? String } == ["a", "b"])
        #expect(playlist.map { $0["title"] as? String } == ["Video a", "Video b"])
        #expect(playlist.map { $0["channelTitle"] as? String } == ["Feed title", "Feed title"])
    }

    @Test func absentValuesAreNull() throws {
        let preparing = AlarmRunStatus(phase: .preparing(scheduledFor: .now), playlist: [], nowPlaying: nil, outputName: nil, volume: nil)
        let json = try object(RemoteState(preparing, macName: "Mac"))
        #expect(json["phase"] as? String == "preparing")
        for key in ["video", "duration", "volume", "outputName"] { #expect(json[key] is NSNull, "\(key)") }
        #expect(json["index"] as? Int == 0 && json["count"] as? Int == 0 && json["position"] as? Double == 0)
        #expect((json["playlist"] as? [Any])?.isEmpty == true)
    }

    @Test func phaseNames() throws {
        func phase(_ status: AlarmRunStatus) throws -> (String?, Bool?) {
            let json = try object(RemoteState(status, macName: "Mac"))
            return (json["phase"] as? String, json["isLoading"] as? Bool)
        }
        var status = AlarmRunStatus.ended
        #expect(try phase(status) == ("ended", false))
        #expect(try object(RemoteState(status, macName: "Mac"))["active"] as? Bool == false)
        status.phase = .starting(output: "JBL Go 3")
        #expect(try phase(status) == ("starting", true))
        status.phase = .alarmSound(reason: "offline")
        #expect(try phase(status) == ("alarmSound", false))
    }

    @Test func choicesAreNewestFirstWithoutDuplicatesOrLiveVideos() throws {
        let known = [video("old", minutesAgo: 60), video("new", minutesAgo: 1), video("undated"), video("old", minutesAgo: 60),
                     video("live", minutesAgo: 0, live: .live), video("soon", minutesAgo: 0, live: .upcoming)]
        let json = try object(RemoteChoices(from: known))
        #expect(Set(json.keys) == ["videos"])
        let videos = try #require(json["videos"] as? [[String: Any]])
        #expect(videos.map { $0["id"] as? String } == ["new", "old", "undated"])
        #expect(Set(videos[0].keys) == ["id", "title", "channelTitle", "thumbnailURL", "publishedAt"])
        #expect(videos[0]["publishedAt"] as? String == "2027-01-15T07:59:00Z")
        #expect(videos[2]["publishedAt"] is NSNull)

        let many = (0..<50).map { video("v\($0)", minutesAgo: Double($0)) }
        #expect(RemoteChoices(from: many).videos.map(\.id) == (0..<40).map { "v\($0)" })
    }
}

@MainActor
struct RemoteAPITests {
    let run = FakeRunControl(playingStatus())

    private func api() -> RemoteAPI {
        RemoteAPI(run: run, key: remoteTestKey, macName: "Mac", now: { remoteTestNow })
    }

    @Test func rejectsUnsignedRequestsAndLogsOnce() async {
        let api = api()
        var request = signedRequest()
        request.headers["x-stow-signature"] = nil
        #expect(await api.handle(request).status == .unauthorized)
        #expect(await api.handle(signedRequest(key: .init(size: .bits256))).status == .unauthorized)
        #expect(run.logs.count == 1)
    }

    @Test func routes() async throws {
        let api = api()
        let state = await api.handle(signedRequest())
        #expect(state.status == .ok)
        #expect(try JSONSerialization.jsonObject(with: state.body) as? [String: Any] != nil)
        #expect(await api.handle(signedRequest("GET", "/v1/choices")).status == .ok)
        #expect(await api.handle(signedRequest("GET", "/v2/state")).status == .notFound)
        #expect(await api.handle(signedRequest("POST", "/v1/state")).status == .methodNotAllowed)
        #expect(await api.handle(signedRequest("GET", "/v1/action")).status == .methodNotAllowed)
        #expect(await api.handle(signedRequest("POST", "/v1/action", body: "{}")).status == .badRequest)
    }

    @Test func carriesOutActions() async {
        let api = api()
        #expect(await api.handle(signedRequest("POST", "/v1/action", body: #"{"action":"next"}"#)).status == .ok)
        #expect(await api.handle(signedRequest("POST", "/v1/action", body: #"{"action":"setVolume","volume":55}"#)).status == .ok)
        #expect(run.performed == [.next])
        #expect(run.volumes == [55])

        let stopped = await api.handle(signedRequest("POST", "/v1/action", body: #"{"action":"stop"}"#))
        #expect(run.stops == 1)
        let json = try? JSONSerialization.jsonObject(with: stopped.body) as? [String: Any]
        #expect(json?["active"] as? Bool == false && json?["phase"] as? String == "ended")
        #expect(await api.handle(signedRequest("POST", "/v1/action", body: #"{"action":"next"}"#)).status == .conflict)
    }
}
