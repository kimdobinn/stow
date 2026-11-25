import Foundation

/// yt-dlp's answers for videos about to be played, kept for a while. mpv runs its yt-dlp through
/// `wrapper(realYtDlp:)`, which hands back a recent answer instead of looking the video up again
/// (about 3 seconds), so a video Stow looked up ahead starts almost at once.
enum StreamCache {
    /// Stream addresses stay valid for about six hours; reuse answers for less than that.
    static let lifetime: TimeInterval = 2 * 60 * 60

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "dev.stow.mac/streams", directoryHint: .isDirectory)
    }

    /// The arguments mpv's ytdl_hook gives yt-dlp (with `ytdl-format` = `format`), so an answer
    /// looked up here is exactly what mpv would have got.
    static func arguments(videoId: String, format: String, cookies: URL?) -> [String] {
        var arguments = ["--no-warnings", "-J", "--flat-playlist", "--sub-format", "ass/srt/best",
                         "--format", format, "--sub-langs", "all", "--write-srt", "--no-playlist"]
        if let cookies { arguments += ["--cookies", cookies.path] }
        return arguments + ["--", "https://www.youtube.com/watch?v=\(videoId)"]
    }

    static func file(for videoId: String, in directory: URL = directory) -> URL {
        directory.appending(path: "\(videoId).json")
    }

    static func isFresh(_ videoId: String, in directory: URL = directory, now: Date = .now) -> Bool {
        guard let modified = try? file(for: videoId, in: directory).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else { return false }
        return now.timeIntervalSince(modified) < lifetime
    }

    /// The saved answer for `videoId`, if it's recent enough to use.
    static func cached(_ videoId: String, in directory: URL = directory, now: Date = .now) -> Data? {
        guard isFresh(videoId, in: directory, now: now) else { return nil }
        return try? Data(contentsOf: file(for: videoId, in: directory))
    }

    /// Keeps yt-dlp's answer for `videoId`, unless it's a live or upcoming stream (those addresses
    /// don't keep) or not a video at all.
    @discardableResult
    static func store(json: Data, videoId: String, in directory: URL = directory) -> Bool {
        guard let info = try? JSONDecoder().decode(Info.self, from: json), info.id == videoId,
              info.live_status != "is_live", info.live_status != "is_upcoming", info.is_live != true else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try json.write(to: file(for: videoId, in: directory), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(for: videoId, in: directory).path)
            return true
        } catch {
            return false
        }
    }

    /// yt-dlp's answer for `videoId`, as mpv would get it. A signed-in lookup that fails is tried
    /// again without the sign-in (enough for any video that isn't members-only), like the wrapper.
    static func lookUp(videoId: String, cookiesFile: URL?) async -> Data? {
        if let cookiesFile {
            let cookies = try? CookieCopy.make(of: cookiesFile)
            defer { if let cookies { try? FileManager.default.removeItem(at: cookies) } }
            if let cookies, let output = try? await YTDLP().run(arguments(videoId: videoId, format: MPVPlayer.format, cookies: cookies),
                                                                 timeout: .seconds(60)) {
                return output.stdout
            }
        }
        return try? await YTDLP().run(arguments(videoId: videoId, format: MPVPlayer.format, cookies: nil), timeout: .seconds(60)).stdout
    }

    /// Deletes answers too old to use.
    static func removeStale(in directory: URL = directory, now: Date = .now) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) >= lifetime { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Deletes every answer (they depend on the YouTube sign-in).
    static func removeAll(in directory: URL = directory) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
    }

    /// The script mpv runs as its yt-dlp: a fresh cached answer for the video if there is one,
    /// otherwise the real yt-dlp (without the user's yt-dlp config, like every other Stow run).
    static func wrapper(realYtDlp: URL, directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "yt-dlp")
        let text = script(realYtDlp: realYtDlp.path, directory: directory.path, lifetime: Int(lifetime))
        if (try? String(contentsOf: url, encoding: .utf8)) != text {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func script(realYtDlp: String, directory: String, lifetime: Int) -> String {
        let workaround = YTDLP.youTubeWorkaround.map(quoted).joined(separator: " ")
        return """
        #!/bin/sh
        # Written by Stow. mpv looks YouTube videos up through this: an answer Stow fetched in the
        # last \(lifetime / 60) minutes (yt-dlp -J with these same arguments) is reused, anything else runs yt-dlp.
        url=""
        for arg in "$@"; do url="$arg"; done
        id=$(printf '%s' "$url" | sed -n 's/.*[?&]v=\\([A-Za-z0-9_-]\\{11\\}\\).*/\\1/p')
        cache=\(quoted(directory))/"$id.json"
        if [ -n "$id" ] && [ -s "$cache" ]; then
          age=$(( $(date +%s) - $(stat -f %m "$cache") ))
          if [ "$age" -lt \(lifetime) ] && cat "$cache"; then exit 0; fi
        fi
        \(quoted(realYtDlp)) --ignore-config \(workaround) "$@" && exit 0
        status=$?
        # A signed-in lookup can fail where a signed-out one works (YouTube's signed-in pages change
        # before yt-dlp catches up): try once more without the sign-in, enough for public videos.
        case "$*" in *--cookies*) ;; *) exit $status ;; esac
        skip=""; first=1
        for arg in "$@"; do
          if [ "$first" = 1 ]; then set --; first=0; fi
          if [ -n "$skip" ]; then skip=""; continue; fi
          case "$arg" in --cookies) skip=1; continue ;; --cookies=*) continue ;; esac
          set -- "$@" "$arg"
        done
        exec \(quoted(realYtDlp)) --ignore-config \(workaround) "$@"

        """
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct Info: Decodable {
        var id: String?
        var live_status: String?
        var is_live: Bool?
    }
}

/// Looks videos up ahead of playback (when the pointer rests on one), a couple at a time.
@MainActor
final class StreamPrefetcher {
    static let shared = StreamPrefetcher()
    static let maxConcurrent = 2

    private var inFlight: Set<String> = []
    private var waiting: [(id: String, cookiesFile: URL?)] = []

    func prefetch(videoId: String, cookiesFile: URL?) {
        guard !inFlight.contains(videoId), !waiting.contains(where: { $0.id == videoId }),
              !StreamCache.isFresh(videoId) else { return }
        waiting.append((videoId, cookiesFile))
        startNext()
    }

    private func startNext() {
        while inFlight.count < Self.maxConcurrent, !waiting.isEmpty {
            let next = waiting.removeLast()   // the latest hovered first
            inFlight.insert(next.id)
            Task {
                await Self.lookUp(videoId: next.id, cookiesFile: next.cookiesFile)
                inFlight.remove(next.id)
                startNext()
            }
        }
    }

    private nonisolated static func lookUp(videoId: String, cookiesFile: URL?) async {
        guard let json = await StreamCache.lookUp(videoId: videoId, cookiesFile: cookiesFile) else { return }
        StreamCache.store(json: json, videoId: videoId)
    }
}
