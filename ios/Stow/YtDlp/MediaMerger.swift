@preconcurrency import AVFoundation
import Foundation

/// Puts a video-only and an audio-only file into one .mp4 without re-encoding (yt-dlp would use
/// ffmpeg, which iOS doesn't have). Works for what YouTube serves as H.264 and AAC (m4a).
nonisolated enum MediaMerger {
    static func merge(video: URL, audio: URL?, to output: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw YtDlpError.mergeFailed("the video file has no picture")
        }
        let videoRange = try await trueRange(of: sourceVideo, in: video)

        // Tracks don't keep their asset alive, and inserting from a freed one fails (-12780).
        let audioAsset = audio.map { AVURLAsset(url: $0) }
        var sourceAudio: AVAssetTrack?
        var audioRange: CMTimeRange?
        if let audioAsset, let audio {
            sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first
            guard let sourceAudio else { throw YtDlpError.mergeFailed("the audio file has no sound") }
            audioRange = try await trueRange(of: sourceAudio, in: audio)
        } else if let track = try await videoAsset.loadTracks(withMediaType: .audio).first {
            sourceAudio = track
            audioRange = try await trueRange(of: track, in: video)
        }

        // Each track whole, as ffmpeg would: YouTube's audio often runs a little past the picture.
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw YtDlpError.mergeFailed("no video track")
        }
        try videoTrack.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        if let sourceAudio, let audioRange {
            guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw YtDlpError.mergeFailed("no audio track")
            }
            try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: .zero)
        }

        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw YtDlpError.mergeFailed("AVFoundation can't export this")
        }
        // The index at the front, so the file starts playing before it is fully read.
        session.shouldOptimizeForNetworkUse = true
        if #available(iOS 18, *) {
            do {
                try await session.export(to: output, as: .mp4)
            } catch {
                throw YtDlpError.mergeFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            if session.status != .completed {
                throw YtDlpError.mergeFailed(session.error?.localizedDescription ?? "export didn't finish")
            }
        }
        withExtendedLifetime((videoAsset, audioAsset)) {}
    }

    /// AVFoundation reports YouTube's fragmented (DASH) MP4 tracks as twice their length (it counts
    /// the fragments twice; the samples themselves are right). The file's own header says how long
    /// it is: mvhd, or the sidx index when the header leaves it open.
    private static func trueRange(of track: AVAssetTrack, in file: URL) async throws -> CMTimeRange {
        let reported = try await track.load(.timeRange)
        guard let declared = MP4Header.duration(of: file), declared > .zero, declared < reported.duration else {
            return reported
        }
        return CMTimeRange(start: reported.start, duration: declared)
    }

    /// The tracks a saved file has (for checks).
    static func trackCounts(of file: URL) async throws -> (video: Int, audio: Int, duration: TimeInterval) {
        let asset = AVURLAsset(url: file)
        let video = try await asset.loadTracks(withMediaType: .video).count
        let audio = try await asset.loadTracks(withMediaType: .audio).count
        let duration = try await asset.load(.duration).seconds
        return (video, audio, duration)
    }
}

/// Just enough of the ISO base media file format to read a file's declared duration.
nonisolated enum MP4Header {
    static func duration(of file: URL) -> CMTime? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // moov and sidx come before the media in YouTube's files; stop at the first fragment.
        var offset: UInt64 = 0
        var fromIndex: CMTime?
        while let header = read(handle, at: offset, count: 16), header.count >= 8 {
            var size = UInt64(header.uint32(at: 0))
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var bodyOffset = offset + 8
            if size == 1, header.count >= 16 {
                size = header.uint64(at: 8)
                bodyOffset = offset + 16
            }
            guard size >= 8 else { return fromIndex }
            switch type {
            case "moov":
                if let duration = movieDuration(handle, from: bodyOffset, to: offset + size), duration > .zero {
                    return duration
                }
            case "sidx":
                if let body = read(handle, at: bodyOffset, count: Int(min(size - (bodyOffset - offset), 1 << 20))) {
                    fromIndex = indexDuration(body)
                }
            case "moof", "mdat":
                return fromIndex
            default:
                break
            }
            offset += size
        }
        return fromIndex
    }

    private static func movieDuration(_ handle: FileHandle, from start: UInt64, to end: UInt64) -> CMTime? {
        var offset = start
        while offset + 8 <= end, let header = read(handle, at: offset, count: 8), header.count == 8 {
            let size = UInt64(header.uint32(at: 0))
            guard size >= 8 else { return nil }
            if String(decoding: header[4..<8], as: UTF8.self) == "mvhd",
               let body = read(handle, at: offset + 8, count: 32), body.count >= 20 {
                if body[0] == 1, body.count >= 32 {
                    return time(body.uint64(at: 24), scale: body.uint32(at: 20))
                }
                return time(UInt64(body.uint32(at: 16)), scale: body.uint32(at: 12))
            }
            offset += size
        }
        return nil
    }

    private static func indexDuration(_ body: Data) -> CMTime? {
        guard body.count >= 12 else { return nil }
        let scale = body.uint32(at: 8)
        let referencesAt = body[0] == 0 ? 20 : 28
        guard body.count >= referencesAt + 4 else { return nil }
        let count = Int(body.uint16(at: referencesAt + 2))
        var total: UInt64 = 0
        for index in 0..<count {
            let at = referencesAt + 4 + index * 12
            guard body.count >= at + 12 else { return nil }
            total += UInt64(body.uint32(at: at + 4))
        }
        return time(total, scale: scale)
    }

    private static func time(_ value: UInt64, scale: UInt32) -> CMTime? {
        guard scale > 0, value > 0, value < UInt64(Int64.max) else { return nil }
        return CMTime(value: CMTimeValue(value), timescale: CMTimeScale(scale))
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }
}

nonisolated private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        self[startIndex + offset..<startIndex + offset + 2].reduce(0) { $0 << 8 | UInt16($1) }
    }

    func uint32(at offset: Int) -> UInt32 {
        self[startIndex + offset..<startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        self[startIndex + offset..<startIndex + offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
