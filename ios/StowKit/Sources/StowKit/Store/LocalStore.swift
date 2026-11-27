import Foundation
import Observation

/// Download state, files and playback positions per video, saved as JSON in Application Support,
/// with the files themselves in its Downloads folder (kept out of backups).
@MainActor
@Observable
public final class LocalStore {
    public private(set) var videos: [String: LocalVideo]
    @ObservationIgnored public let directory: URL
    @ObservationIgnored private let file: URL
    /// Called after every change (the Repository rebuilds its items).
    @ObservationIgnored var onChange: (() -> Void)?

    /// `directory` is the app's Application Support folder (a temporary one in tests).
    public init(directory: URL) {
        self.directory = directory
        file = directory.appending(path: "videos.json")
        videos = (try? Data(contentsOf: file)).flatMap { data in
            try? JSONDecoder.stow.decode([LocalVideo].self, from: data)
        }.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { $1 }) } ?? [:]
    }

    public subscript(_ id: String) -> LocalVideo? { videos[id] }

    /// Where downloads go: Application Support/Downloads, not backed up (videos can be fetched again).
    public var downloadsDirectory: URL {
        var url = directory.appending(path: "Downloads", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    /// The downloaded file, when there is one on disk.
    public func fileURL(for id: String) -> URL? {
        guard let name = videos[id]?.fileName else { return nil }
        let url = downloadsDirectory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func update(_ id: String, _ change: (LocalVideo?) -> LocalVideo?) {
        if var updated = change(videos[id]) {
            updated.updatedAt = .now
            videos[id] = updated
        } else {
            videos[id] = nil
        }
        save()
        onChange?()
    }

    /// Progress changes often; they skip the disk (the next real change saves them).
    func setProgress(_ id: String, _ percent: Int) {
        guard var video = videos[id], video.progress != percent else { return }
        video.progress = percent
        videos[id] = video
        onChange?()
    }

    public func clear() {
        videos = [:]
        save()
        onChange?()
    }

    /// Every file in the downloads folder whose name starts with the video's id, and its partial download.
    public func deleteFiles(for id: String) {
        let folder = downloadsDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("\(id).") {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        try? FileManager.default.removeItem(at: partsDirectory(for: id))
    }

    /// Where the YouTube tool keeps a video's unfinished download (see `YouTubeTool.download`).
    public func partsDirectory(for id: String) -> URL {
        downloadsDirectory.appending(path: Self.partsFolder, directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory)
    }

    public static let partsFolder = ".parts"

    public func storageUsedBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: downloadsDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let list = videos.values.sorted { $0.id < $1.id }
        if let data = try? JSONEncoder.stow.encode(list) { try? data.write(to: file, options: .atomic) }
    }
}

extension JSONEncoder {
    static var stow: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var stow: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
