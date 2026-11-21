import CoreGraphics
import Foundation

/// YouTube's timeline preview frames: sprite sheets of `rows` × `columns` small frames, one every
/// `interval` seconds, listed by yt-dlp as the "storyboard" formats.
struct Storyboard: Equatable, Sendable {
    var frameWidth: Int
    var frameHeight: Int
    var rows: Int
    var columns: Int
    /// Seconds between frames.
    var interval: TimeInterval
    var duration: TimeInterval
    /// The sheets in order; each holds `rows * columns` frames.
    var sheets: [URL]

    /// One frame: which sheet, and where in it (in the sheet's pixels, top-left origin).
    struct Frame: Equatable, Sendable {
        var sheet: URL
        var rect: CGRect
    }

    var framesPerSheet: Int { rows * columns }

    /// The frame shown at `time` seconds.
    func frame(at time: TimeInterval) -> Frame? {
        guard !sheets.isEmpty, framesPerSheet > 0, interval > 0 else { return nil }
        let total = min(sheets.count * framesPerSheet, max(Int((duration / interval).rounded(.up)), 1))
        let index = min(max(Int(max(time, 0) / interval), 0), total - 1)
        let cell = index % framesPerSheet
        let rect = CGRect(x: (cell % columns) * frameWidth, y: (cell / columns) * frameHeight,
                          width: frameWidth, height: frameHeight)
        return Frame(sheet: sheets[index / framesPerSheet], rect: rect)
    }

    /// The sharpest storyboard in yt-dlp's video JSON (`-J`), or nil when it lists none.
    static func parse(json: Data) -> Storyboard? {
        guard let info = try? JSONDecoder().decode(Info.self, from: json), let duration = info.duration,
              duration > 0 else { return nil }
        let boards = (info.formats ?? []).compactMap { format -> Storyboard? in
            guard format.format_note == "storyboard", let width = format.width, let height = format.height,
                  let rows = format.rows, let columns = format.columns, let fps = format.fps, fps > 0,
                  let fragments = format.fragments, !fragments.isEmpty else { return nil }
            let sheets = fragments.compactMap { URL(string: $0.url) }
            guard sheets.count == fragments.count else { return nil }
            return Storyboard(frameWidth: width, frameHeight: height, rows: rows, columns: columns,
                              interval: 1 / fps, duration: duration, sheets: sheets)
        }
        return boards.max { $0.frameWidth < $1.frameWidth }
    }

    private struct Info: Decodable {
        var duration: Double?
        var formats: [Format]?
    }

    private struct Format: Decodable {
        var format_note: String?
        var width: Int?
        var height: Int?
        var rows: Int?
        var columns: Int?
        var fps: Double?
        var fragments: [Fragment]?
    }

    private struct Fragment: Decodable {
        var url: String
    }
}
