import Foundation
import ImageIO
import Observation

/// Fetches the timeline preview frames for the video being watched: the storyboard (from the
/// lookup saved for playback, else one `yt-dlp -J` run per video) and its sheets, as the pointer
/// reaches them.
@MainActor
@Observable
final class StoryboardLoader {
    static let shared = StoryboardLoader()

    /// The storyboard of `videoId`, once looked up (nil while loading, or when it has none).
    private(set) var storyboard: Storyboard?
    private(set) var videoId: String?
    /// Decoded sheets, most recently used last.
    private(set) var sheets: [URL: CGImage] = [:]
    @ObservationIgnored private var recent: [URL] = []
    @ObservationIgnored private var fetching: Set<URL> = []
    @ObservationIgnored private var lookUp: Task<Void, Never>?
    static let maxSheets = 40

    /// Starts looking up `videoId`'s storyboard, forgetting the previous video's.
    func load(videoId: String, cookiesFile: URL?) {
        guard videoId != self.videoId else { return }
        lookUp?.cancel()
        self.videoId = videoId
        storyboard = nil
        sheets = [:]
        recent = []
        fetching = []
        lookUp = Task { [weak self] in
            let found = await Self.fetchStoryboard(videoId: videoId, cookiesFile: cookiesFile)
            guard !Task.isCancelled, let self, self.videoId == videoId else { return }
            self.storyboard = found
        }
    }

    /// The frame at `time`, when its sheet is here; otherwise starts fetching the sheet.
    func image(at time: TimeInterval) -> CGImage? {
        guard let storyboard, let frame = storyboard.frame(at: time) else { return nil }
        guard let sheet = sheets[frame.sheet] else {
            fetch(frame.sheet)
            return nil
        }
        return sheet.cropping(to: frame.rect)
    }

    private func fetch(_ url: URL) {
        guard fetching.insert(url).inserted else { return }
        let videoId = videoId
        Task { [weak self] in
            let image = await Self.download(url)
            guard let self, self.videoId == videoId else { return }
            self.fetching.remove(url)
            guard let image else { return }
            self.sheets[url] = image
            self.recent.append(url)
            while self.recent.count > Self.maxSheets {
                self.sheets[self.recent.removeFirst()] = nil
            }
        }
    }

    private nonisolated static func fetchStoryboard(videoId: String, cookiesFile: URL?) async -> Storyboard? {
        // The answer looked up ahead for playback lists the storyboards too.
        if let saved = StreamCache.cached(videoId), let storyboard = Storyboard.parse(json: saved) {
            return storyboard
        }
        // The same lookup mpv makes (members-only videos need the sign-in), kept for the next time
        // this video plays.
        guard let json = await StreamCache.lookUp(videoId: videoId, cookiesFile: cookiesFile) else { return nil }
        StreamCache.store(json: json, videoId: videoId)
        return Storyboard.parse(json: json)
    }

    private nonisolated static func download(_ url: URL) async -> CGImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
