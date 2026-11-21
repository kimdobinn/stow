import Foundation
import Testing
@testable import Stow

struct StoryboardTests {
    private let json = Data("""
    {"id": "abc", "duration": 213, "formats": [
      {"format_id": "sb1", "format_note": "storyboard", "width": 160, "height": 90, "rows": 5, "columns": 5,
       "fps": 0.507, "fragments": [{"url": "https://i.ytimg.com/sb/abc/L2/M0.jpg", "duration": 49.3}]},
      {"format_id": "sb0", "format_note": "storyboard", "width": 320, "height": 180, "rows": 3, "columns": 3,
       "fps": 0.5070422535211268, "fragments": [
         {"url": "https://i.ytimg.com/sb/abc/L3/M0.jpg?sigh=rs$A", "duration": 17.75},
         {"url": "https://i.ytimg.com/sb/abc/L3/M1.jpg?sigh=rs$A", "duration": 17.75}]},
      {"format_id": "18", "format_note": "360p", "width": 640, "height": 360}
    ]}
    """.utf8)

    @Test func picksTheSharpestStoryboard() throws {
        let board = try #require(Storyboard.parse(json: json))
        #expect(board.frameWidth == 320)
        #expect(board.frameHeight == 180)
        #expect(board.framesPerSheet == 9)
        #expect(board.sheets.count == 2)
        #expect(abs(board.interval - 1.9722) < 0.001)
    }

    @Test func findsTheFrameForATime() throws {
        let board = try #require(Storyboard.parse(json: json))
        #expect(board.frame(at: 0) == .init(sheet: board.sheets[0], rect: CGRect(x: 0, y: 0, width: 320, height: 180)))
        // Frame 4: middle of the first sheet.
        #expect(board.frame(at: 4 * board.interval + 0.1)?.rect == CGRect(x: 320, y: 180, width: 320, height: 180))
        // Frame 10: second sheet, second cell.
        let frame = try #require(board.frame(at: 10 * board.interval + 0.1))
        #expect(frame.sheet == board.sheets[1])
        #expect(frame.rect.origin == CGPoint(x: 320, y: 0))
        // Past the last sheet: its last frame.
        #expect(board.frame(at: 10_000)?.sheet == board.sheets[1])
        #expect(board.frame(at: -5)?.rect.origin == .zero)
    }

    @Test func noStoryboardIsNil() {
        #expect(Storyboard.parse(json: Data(#"{"duration": 10, "formats": [{"format_note": "360p"}]}"#.utf8)) == nil)
        #expect(Storyboard.parse(json: Data("not json".utf8)) == nil)
    }
}
