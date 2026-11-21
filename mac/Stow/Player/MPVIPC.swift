import Foundation

/// One argument of an mpv JSON IPC command.
enum MPVArgument: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// The mpv commands the player sends.
enum MPVCommand: Equatable, Sendable {
    case observeProperty(id: Int, name: String)
    case getProperty(String)
    case requestLogMessages(level: String)
    case seekAbsolute(TimeInterval)
    case seekRelative(TimeInterval)
    case setPause(Bool)
    case setVolume(Double)
    case setMute(Bool)
    case playlistNext
    /// 0-based playlist position.
    case playlistPlayIndex(Int)
    /// Adds `url` to the end of the playlist without playing it.
    case appendFile(URL)
    case quit

    var arguments: [MPVArgument] {
        switch self {
        case .observeProperty(let id, let name): [.string("observe_property"), .int(id), .string(name)]
        case .getProperty(let name): [.string("get_property"), .string(name)]
        case .requestLogMessages(let level): [.string("request_log_messages"), .string(level)]
        case .seekAbsolute(let seconds): [.string("seek"), .double(seconds), .string("absolute")]
        case .seekRelative(let seconds): [.string("seek"), .double(seconds), .string("relative")]
        case .setPause(let paused): [.string("set_property"), .string("pause"), .bool(paused)]
        case .setVolume(let volume): [.string("set_property"), .string("volume"), .double(volume)]
        case .setMute(let muted): [.string("set_property"), .string("mute"), .bool(muted)]
        case .playlistNext: [.string("playlist-next")]
        case .playlistPlayIndex(let index): [.string("playlist-play-index"), .int(index)]
        case .appendFile(let url): [.string("loadfile"), .string(url.absoluteString), .string("append")]
        case .quit: [.string("quit")]
        }
    }
}

enum MPVEndReason: String, Sendable {
    case eof, stop, quit, error, redirect, unknown
}

enum MPVEvent: Equatable, Sendable {
    case startFile(entryId: Int?)
    /// Playback (re)started after loading or seeking.
    case playbackRestart
    case endFile(entryId: Int?, reason: MPVEndReason, error: String?)
    /// A numeric observed property; nil when it became unavailable.
    case propertyChange(name: String, value: Double?)
    /// A boolean observed property (e.g. `pause`).
    case flagChange(name: String, value: Bool)
    case logMessage(level: String, prefix: String, text: String)
    case other(String)
}

enum MPVMessage: Equatable, Sendable {
    case reply(requestId: Int?, success: Bool, number: Double?)
    case event(MPVEvent)
}

/// mpv's JSON IPC protocol: newline-delimited JSON objects in both directions.
enum MPVIPC {
    private struct Request: Encodable {
        var command: [MPVArgument]
        var request_id: Int
    }

    /// One command line, newline-terminated.
    static func encode(_ command: MPVCommand, requestId: Int) -> Data {
        var data = (try? JSONEncoder().encode(Request(command: command.arguments, request_id: requestId))) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Parses one line; nil when it isn't a JSON object mpv would send.
    static func parse(_ line: Data) -> MPVMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        if let event = object["event"] as? String {
            return .event(parseEvent(event, object))
        }
        guard let error = object["error"] as? String else { return nil }
        return .reply(requestId: object["request_id"] as? Int, success: error == "success",
                      number: number(object["data"]))
    }

    private static func parseEvent(_ name: String, _ object: [String: Any]) -> MPVEvent {
        switch name {
        case "start-file":
            return .startFile(entryId: object["playlist_entry_id"] as? Int)
        case "playback-restart":
            return .playbackRestart
        case "end-file":
            return .endFile(entryId: object["playlist_entry_id"] as? Int,
                            reason: (object["reason"] as? String).flatMap(MPVEndReason.init) ?? .unknown,
                            error: object["file_error"] as? String)
        case "property-change":
            let name = object["name"] as? String ?? ""
            if let flag = object["data"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
                return .flagChange(name: name, value: flag.boolValue)
            }
            return .propertyChange(name: name, value: number(object["data"]))
        case "log-message":
            return .logMessage(level: object["level"] as? String ?? "",
                               prefix: object["prefix"] as? String ?? "",
                               text: (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return .other(name)
        }
    }

    /// JSONSerialization gives NSNumber; booleans are not numbers here.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
