import Foundation
import Testing
@testable import Stow

struct MPVIPCTests {
    private func json(_ command: MPVCommand, id: Int = 7) throws -> [String: Any] {
        let data = MPVIPC.encode(command, requestId: id)
        #expect(data.last == 0x0A)
        #expect(data.dropLast().contains(0x0A) == false)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func encodesCommandsWithRequestId() throws {
        let observe = try json(.observeProperty(id: 1, name: "time-pos"))
        #expect(observe["request_id"] as? Int == 7)
        #expect(observe["command"] as? [AnyHashable] == ["observe_property", 1, "time-pos"])
        #expect(try json(.quit)["command"] as? [String] == ["quit"])
        #expect(try json(.getProperty("playlist-pos"))["command"] as? [String] == ["get_property", "playlist-pos"])
        #expect(try json(.requestLogMessages(level: "error"))["command"] as? [String] == ["request_log_messages", "error"])
    }

    @Test func encodesSeekAsNumber() throws {
        let command = try #require(try json(.seekAbsolute(83.5))["command"] as? [Any])
        #expect(command[0] as? String == "seek")
        #expect((command[1] as? NSNumber)?.doubleValue == 83.5)
        #expect(command[2] as? String == "absolute")
    }

    @Test func encodesControlCommands() throws {
        let pause = try #require(try json(.setPause(true))["command"] as? [Any])
        #expect(pause[0] as? String == "set_property")
        #expect(pause[1] as? String == "pause")
        #expect((pause[2] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true)
        let seek = try #require(try json(.seekRelative(-10))["command"] as? [Any])
        #expect(seek[0] as? String == "seek")
        #expect((seek[1] as? NSNumber)?.doubleValue == -10)
        #expect(seek[2] as? String == "relative")
        #expect(try json(.playlistNext)["command"] as? [String] == ["playlist-next"])
    }

    @Test func parsesBooleanPropertiesAsFlags() {
        #expect(parse(#"{"event":"property-change","id":3,"name":"pause","data":true}"#)
                == .event(.flagChange(name: "pause", value: true)))
        #expect(parse(#"{"event":"property-change","id":1,"name":"time-pos","data":12.5}"#)
                == .event(.propertyChange(name: "time-pos", value: 12.5)))
    }

    private func parse(_ line: String) -> MPVMessage? {
        MPVIPC.parse(Data(line.utf8))
    }

    @Test func parsesReplies() {
        #expect(parse(#"{"request_id":1,"error":"success"}"#) == .reply(requestId: 1, success: true, number: nil))
        #expect(parse(#"{"data":0,"request_id":4,"error":"success"}"#) == .reply(requestId: 4, success: true, number: 0))
        #expect(parse(#"{"data":{},"request_id":5,"error":"invalid parameter"}"#)
                == .reply(requestId: 5, success: false, number: nil))
        #expect(parse(#"{"data":true,"request_id":6,"error":"success"}"#) == .reply(requestId: 6, success: true, number: nil))
    }

    @Test func parsesPlaybackEvents() {
        #expect(parse(#"{"event":"start-file","playlist_entry_id":2}"#) == .event(.startFile(entryId: 2)))
        #expect(parse(#"{"event":"playback-restart"}"#) == .event(.playbackRestart))
        #expect(parse(#"{"event":"end-file","reason":"eof","playlist_entry_id":1}"#)
                == .event(.endFile(entryId: 1, reason: .eof, error: nil)))
        #expect(parse(#"{"event":"end-file","reason":"error","playlist_entry_id":2,"file_error":"unrecognized file format"}"#)
                == .event(.endFile(entryId: 2, reason: .error, error: "unrecognized file format")))
        #expect(parse(#"{"event":"end-file","reason":"something-new"}"#)
                == .event(.endFile(entryId: nil, reason: .unknown, error: nil)))
        #expect(parse(#"{"event":"audio-reconfig"}"#) == .event(.other("audio-reconfig")))
    }

    @Test func parsesPropertyChanges() {
        #expect(parse(#"{"event":"property-change","id":1,"name":"time-pos","data":5.960000}"#)
                == .event(.propertyChange(name: "time-pos", value: 5.96)))
        #expect(parse(#"{"event":"property-change","id":2,"name":"duration"}"#)
                == .event(.propertyChange(name: "duration", value: nil)))
    }

    @Test func parsesLogMessages() {
        let line = #"{"event":"log-message","prefix":"ytdl_hook","level":"error","text":"ERROR: [youtube] x: This video is unavailable\n"}"#
        #expect(parse(line) == .event(.logMessage(level: "error", prefix: "ytdl_hook",
                                                  text: "ERROR: [youtube] x: This video is unavailable")))
    }

    @Test func rejectsGarbage() {
        #expect(parse("") == nil)
        #expect(parse("not json") == nil)
        #expect(parse("[1,2]") == nil)
        #expect(parse(#"{"request_id":1}"#) == nil)
    }
}
