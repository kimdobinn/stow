import AppKit
import Testing
@testable import Stow

struct ScrollGlideTests {
    @Test func notchesAddUpAndStopAtTheEnds() {
        var glide = ScrollGlide(at: 100)
        glide.add(80, within: 0...1000)
        glide.add(80, within: 0...1000)
        #expect(glide.target == 260)
        glide.add(-5000, within: 0...1000)
        #expect(glide.target == 0)
        glide.add(5000, within: 0...1000)
        #expect(glide.target == 1000)
    }

    @Test func easesTowardTheTargetAndLands() {
        var glide = ScrollGlide(at: 0)
        glide.add(100, within: 0...1000)
        let first = glide.step(elapsed: 1.0 / 60)
        #expect(first > 0 && first < 50)
        var position = first
        for _ in 0..<60 { position = glide.step(elapsed: 1.0 / 60) }
        #expect(position == 100)
        #expect(glide.isSettled)
    }

    @Test func aLongFrameDoesNotOvershoot() {
        var glide = ScrollGlide(at: 0)
        glide.add(100, within: 0...1000)
        #expect(glide.step(elapsed: 5) == 100)
        #expect(glide.step(elapsed: -1) == 100)
    }
}

struct ScrollSettingsTests {
    @Test func decodesMissingAndOutOfRangeValues() throws {
        let empty = try JSONDecoder().decode(ScrollSettings.self, from: Data("{}".utf8))
        #expect(empty == .default)
        let wild = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"speed": 40, "smooth": false}"#.utf8))
        #expect(wild == ScrollSettings(speed: ScrollSettings.speedRange.upperBound, smooth: false))
    }

    @Test func oldSettingsFilesGetTheDefault() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"channels": []}"#.utf8))
        #expect(settings.scrolling == .default)
        let broken = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"scrolling": "fast"}"#.utf8))
        #expect(broken.scrolling == .default)
    }
}

@MainActor
struct ScrollEngineTests {
    /// A 400×300 window whose vertical scroll view holds a 400×3000 flipped document.
    private func makeWindow() -> (NSWindow, NSScrollView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.verticalLineScroll = 10
        scrollView.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
        window.contentView = scrollView
        return (window, scrollView)
    }

    private func wheel(lines: Int32) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
        // Global coordinates start at the top of the main screen; the window sits at its bottom left.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: 200, y: screenHeight - 150)
        return NSEvent(cgEvent: event)!
    }

    private func settle(_ engine: ScrollEngine) {
        for _ in 0..<120 where engine.isGliding { engine.advance(by: 1.0 / 60) }
    }

    @Test func wheelNotchesGlideDownByLineTimesSpeed() {
        let (window, scrollView) = makeWindow()
        let engine = ScrollEngine()
        engine.use { ScrollSettings(speed: 3, smooth: true) }
        let event = wheel(lines: -1)
        #expect(engine.handle(event, in: window) == nil)
        #expect(engine.handle(event, in: window) == nil)
        engine.advance(by: 1.0 / 60)
        let midway = scrollView.contentView.bounds.origin.y
        #expect(midway > 0)
        settle(engine)
        let expected = -2 * event.scrollingDeltaY * 10 * 3
        #expect(abs(scrollView.contentView.bounds.origin.y - expected) < 1)
        #expect(midway < expected)
    }

    @Test func stopsAtTheTop() {
        let (window, scrollView) = makeWindow()
        let engine = ScrollEngine()
        engine.use { ScrollSettings(speed: 3, smooth: true) }
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 40))
        #expect(engine.handle(wheel(lines: 5), in: window) == nil)
        settle(engine)
        #expect(scrollView.contentView.bounds.origin.y == 0)
    }

    @Test func trackpadsAndPlainWheelsPassThrough() {
        let (window, _) = makeWindow()
        let engine = ScrollEngine()
        engine.use { ScrollSettings(speed: 1, smooth: false) }
        let event = wheel(lines: -1)
        #expect(engine.handle(event, in: window) === event)
        engine.use { ScrollSettings(speed: 2, smooth: false) }
        let faster = engine.handle(event, in: window)
        #expect(faster != nil && faster !== event)
        #expect(abs((faster?.scrollingDeltaY ?? 0) - 2 * event.scrollingDeltaY) < 0.01)
    }

    @Test func nothingToScrollLeavesTheEventAlone() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let engine = ScrollEngine()
        engine.use { .default }
        let event = wheel(lines: -1)
        #expect(engine.handle(event, in: window) === event)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
