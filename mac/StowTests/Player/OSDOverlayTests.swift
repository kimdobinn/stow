import Foundation
import Testing
@testable import Stow

struct OSDOverlayTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let morning = Date(timeIntervalSince1970: 8 * 3600 + 5 * 60 + 42)

    @Test func clockIsTwentyFourHour() {
        #expect(OSDOverlay.clockString(morning, timeZone: utc) == "08:05")
        #expect(OSDOverlay.clockString(Date(timeIntervalSince1970: 23 * 3600 + 59 * 60), timeZone: utc) == "23:59")
    }

    @Test func clockOnlyWithoutBanner() {
        let text = OSDOverlay.text(time: morning, banner: nil, timeZone: utc)
        #expect(text.hasPrefix("{\\an9"))
        #expect(text.hasSuffix("}08:05"))
        #expect(!text.contains("\n"))
    }

    @Test func bannerOnSecondLine() {
        let text = OSDOverlay.text(time: morning, banner: "1/3 · Title · Channel", timeZone: utc)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("{\\an7"))
        #expect(lines[1].hasSuffix("}1/3 · Title · Channel"))
    }

    @Test func escapesOverrideBlocksAndLineBreaks() {
        #expect(OSDOverlay.escaped("{\\b1}bold\nnext") == "\\{\\\u{2060}b1\\}bold next")
    }

    @Test func bannerNumbersFromOne() {
        let banner = OSDOverlay.banner(index: 0, count: 3, video: video("a"))
        #expect(banner == "1/3 · Video a · Feed title")
    }

    @Test func bannerTruncatesLongTitles() {
        var long = video("a")
        long.title = String(repeating: "x", count: 200)
        let banner = OSDOverlay.banner(index: 2, count: 3, video: long)
        #expect(banner.hasPrefix("3/3 · " + String(repeating: "x", count: OSDOverlay.maximumTitleLength - 1) + "… · "))
    }
}
