import AVFoundation
import StowKit

/// Turns what yt-dlp found into something AVPlayer plays.
enum StreamItem {
    /// Not a public constant, but the documented-in-practice way to send headers with AVURLAsset.
    static let headersKey = "AVURLAssetHTTPHeaderFieldsKey"

    /// YouTube's HLS manifest plays as it is; separate video and audio play together through a
    /// composition; a single file plays as it is.
    static func make(_ info: StreamInfo) async throws -> AVPlayerItem {
        let video = asset(info.url, headers: isHLS(info.url) ? [:] : info.headers)
        guard let audioURL = info.audioURL else { return AVPlayerItem(asset: video) }
        let audio = asset(audioURL, headers: info.headers)
        let composition = AVMutableComposition()
        let (videoTracks, videoDuration) = try await video.load(.tracks, .duration)
        let (audioTracks, audioDuration) = try await audio.load(.tracks, .duration)
        guard let videoTrack = videoTracks.first(where: { $0.mediaType == .video }) else { throw YtDlpError.noPlayableFormat }
        let length = audioTracks.isEmpty ? videoDuration : CMTimeMinimum(videoDuration, audioDuration)
        let range = CMTimeRange(start: .zero, duration: length)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: videoTrack, at: .zero)
        if let audioTrack = audioTracks.first(where: { $0.mediaType == .audio }) {
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(range, of: audioTrack, at: .zero)
        }
        return AVPlayerItem(asset: composition)
    }

    static func isHLS(_ url: URL) -> Bool {
        url.pathExtension == "m3u8" || url.path.contains("/hls")
    }

    private static func asset(_ url: URL, headers: [String: String]) -> AVURLAsset {
        AVURLAsset(url: url, options: headers.isEmpty ? nil : [headersKey: headers])
    }
}
