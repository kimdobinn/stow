import Foundation

/// Reads and atomically writes the JSON files in the support directory
/// (pretty-printed, sorted keys, ISO 8601 dates).
struct Store {
    /// log.json keeps at most this many entries.
    static let logLimit = 500

    let directory: URL

    init(directory: URL = AppPaths.supportDirectory) {
        self.directory = directory
    }

    var settingsFile: URL { directory.appending(path: AppPaths.settingsFile.lastPathComponent) }
    var stateFile: URL { directory.appending(path: AppPaths.stateFile.lastPathComponent) }
    var logFile: URL { directory.appending(path: AppPaths.logFile.lastPathComponent) }

    /// Returns `.default` when the file doesn't exist; throws when it exists but is malformed.
    /// Values replaced by their defaults are added to `issues`.
    func loadSettings(issues: SettingsIssues? = nil) throws -> AppSettings {
        let decoder = Self.decoder()
        decoder.userInfo[.settingsIssues] = issues
        return try load(settingsFile, decoder: decoder) ?? .default
    }

    /// Keeps keys this version doesn't know, at the top level, inside object sections such as
    /// "alarm", and per channel (by id), so hand-added notes and keys written by a newer build
    /// survive a save. Known sections must therefore encode every key they own (nil as null).
    func save(_ settings: AppSettings) throws {
        var object = try Self.jsonObject(Self.encoder().encode(settings))
        if let data = try? Data(contentsOf: settingsFile), let existing = try? Self.jsonObject(data) {
            object = Self.merge(object, over: existing)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: settingsFile, options: .atomic)
    }

    func loadState() throws -> AppState {
        try load(stateFile) ?? .empty
    }

    func save(_ state: AppState) throws {
        try write(state, to: stateFile)
    }

    /// Oldest first, as stored on disk.
    func loadLog() throws -> [LogEntry] {
        try load(logFile) ?? []
    }

    /// `log` is oldest first; only the newest `logLimit` entries are kept.
    func save(log: [LogEntry]) throws {
        try write(Array(log.suffix(Self.logLimit)), to: logFile)
    }

    func modificationDate(of file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Renames an unreadable file (e.g. "settings.corrupt-1763540000.json") so the
    /// next save doesn't destroy it. Returns the new location.
    @discardableResult
    func quarantine(_ file: URL) throws -> URL {
        let name = "\(file.deletingPathExtension().lastPathComponent).corrupt-\(Int(Date.now.timeIntervalSince1970)).json"
        let destination = file.deletingLastPathComponent().appending(path: name)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    private func load<T: Decodable>(_ file: URL, decoder: JSONDecoder = Store.decoder()) throws -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try Self.encoder().encode(value)
        data.append(0x0A)
        try data.write(to: file, options: .atomic)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    private static func merge(_ settings: [String: Any], over existing: [String: Any]) -> [String: Any] {
        var merged = existing.merging(settings) { old, new in
            guard let old = old as? [String: Any], let new = new as? [String: Any] else { return new }
            return old.merging(new) { _, new in new }
        }
        let oldChannels = existing["channels"] as? [[String: Any]] ?? []
        if let channels = settings["channels"] as? [[String: Any]] {
            merged["channels"] = channels.map { channel in
                guard let old = oldChannels.first(where: { $0["id"] as? String == channel["id"] as? String }) else { return channel }
                return old.merging(channel) { _, new in new }
            }
        }
        return merged
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Accepts ISO 8601 dates with or without fractional seconds, since files may be hand-edited.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(string, strategy: .iso8601) { return date }
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected an ISO 8601 date, got \(string)"))
        }
        return decoder
    }
}
