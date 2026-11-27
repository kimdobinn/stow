import Foundation
import Observation

/// Your playlists, saved as JSON on the phone.
@MainActor
@Observable
public final class PlaylistStore {
    /// Newest first.
    public private(set) var playlists: [Playlist]
    @ObservationIgnored private let file: URL

    public init(directory: URL) {
        file = directory.appending(path: "playlists.json")
        playlists = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.stow.decode([Playlist].self, from: $0) } ?? []
    }

    public func playlist(_ id: String) -> Playlist? { playlists.first { $0.id == id } }

    @discardableResult
    public func create(_ name: String, firstVideo: String? = nil) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(id: UUID().uuidString, name: trimmed.isEmpty ? "Playlist" : trimmed,
                                videoIds: firstVideo.map { [$0] } ?? [], createdAt: .now)
        change { [playlist] + $0 }
        return playlist
    }

    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(id) { if !trimmed.isEmpty { $0.name = trimmed } }
    }

    public func delete(_ id: String) { change { $0.filter { $0.id != id } } }

    public func add(_ id: String, videoId: String) {
        edit(id) { if !$0.videoIds.contains(videoId) { $0.videoIds.append(videoId) } }
    }

    public func remove(_ id: String, videoId: String) { edit(id) { $0.videoIds.removeAll { $0 == videoId } } }

    /// Moves a video one place up (-1) or down (+1).
    public func move(_ id: String, videoId: String, by offset: Int) {
        edit(id) { playlist in
            guard let from = playlist.videoIds.firstIndex(of: videoId) else { return }
            let to = min(max(from + offset, 0), playlist.videoIds.count - 1)
            guard from != to else { return }
            playlist.videoIds.insert(playlist.videoIds.remove(at: from), at: to)
        }
    }

    private func edit(_ id: String, _ transform: (inout Playlist) -> Void) {
        change { list in list.map { playlist in
            guard playlist.id == id else { return playlist }
            var playlist = playlist
            transform(&playlist)
            return playlist
        } }
    }

    private func change(_ transform: ([Playlist]) -> [Playlist]) {
        playlists = transform(playlists)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.stow.encode(playlists) { try? data.write(to: file, options: .atomic) }
    }
}
