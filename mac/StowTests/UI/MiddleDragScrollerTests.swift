import AppKit
import Testing
@testable import Stow

struct ScrollGlideTests {
    @Test func targetStopsAtTheEnds() {
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
        for _ in 0..<120 { position = glide.step(elapsed: 1.0 / 60) }
        #expect(position == 100)
        #expect(glide.isSettled)
        #expect(glide.step(elapsed: -1) == 100)
    }
}

@MainActor
struct MiddleDragScrollerTests {
    /// A 400×300 window: a page scrolling down (2000 tall) holding a 400×100 shelf scrolling
    /// sideways (2000 wide) at the top of what's visible.
    private func makeWindow() -> (NSWindow, page: NSScrollView, shelf: NSScrollView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let page = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        page.documentView = document
        let shelf = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        shelf.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 2000, height: 100))
        document.addSubview(shelf)
        window.contentView = page
        return (window, page, shelf)
    }

    /// A mouse event at window point (x, y) (y up from the bottom); middle button unless it's a left one.
    private func mouse(_ type: CGEventType, x: CGFloat, y: CGFloat, time: TimeInterval) -> NSEvent {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let left = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(type)
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: screenHeight - y),
                            mouseButton: left ? .left : .center)!
        event.timestamp = CGEventTimestamp(time * 1_000_000_000)
        return NSEvent(cgEvent: event)!
    }

    @Test func draggingOverAShelfScrollsItSideways() {
        let (window, page, shelf) = makeWindow()
        let scroller = MiddleDragScroller()
        // The shelf is at the top of the window: window y 200...300.
        #expect(scroller.handle(mouse(.otherMouseDown, x: 300, y: 250, time: 1), in: window) == nil)
        _ = scroller.handle(mouse(.otherMouseDragged, x: 250, y: 250, time: 1.5), in: window)
        _ = scroller.handle(mouse(.otherMouseDragged, x: 200, y: 250, time: 2), in: window)
        #expect(scroller.handle(mouse(.otherMouseUp, x: 200, y: 250, time: 3), in: window) == nil)
        // Dragged 100 left: the shelf shows 100 further right; the page didn't move.
        #expect(shelf.contentView.bounds.origin.x == 100)
        #expect(page.contentView.bounds.origin.y == 0)
        #expect(!scroller.isFlinging)
    }

    @Test func draggingElsewhereScrollsThePageAndStopsAtTheTop() {
        let (window, page, _) = makeWindow()
        let scroller = MiddleDragScroller()
        _ = scroller.handle(mouse(.otherMouseDown, x: 200, y: 100, time: 1), in: window)
        _ = scroller.handle(mouse(.otherMouseDragged, x: 200, y: 150, time: 1.5), in: window)
        _ = scroller.handle(mouse(.otherMouseDragged, x: 200, y: 220, time: 2), in: window)
        // Dragged up 120: the page moves down by as much.
        #expect(page.contentView.bounds.origin.y == 120)
        _ = scroller.handle(mouse(.otherMouseDragged, x: 200, y: -500, time: 2.5), in: window)
        #expect(page.contentView.bounds.origin.y == 0)
        _ = scroller.handle(mouse(.otherMouseUp, x: 200, y: -500, time: 3), in: window)
    }

    @Test func aQuickFlickKeepsGliding() {
        let (window, _, shelf) = makeWindow()
        let scroller = MiddleDragScroller()
        _ = scroller.handle(mouse(.otherMouseDown, x: 300, y: 250, time: 1), in: window)
        _ = scroller.handle(mouse(.otherMouseDragged, x: 290, y: 250, time: 1.01), in: window)
        _ = scroller.handle(mouse(.otherMouseDragged, x: 270, y: 250, time: 1.03), in: window)
        _ = scroller.handle(mouse(.otherMouseUp, x: 270, y: 250, time: 1.04), in: window)
        let released = shelf.contentView.bounds.origin.x
        #expect(released == 30)
        #expect(scroller.isFlinging)
        for _ in 0..<200 where scroller.isFlinging { scroller.advanceFling(by: 1.0 / 60) }
        #expect(shelf.contentView.bounds.origin.x > released + 100)
    }

    @Test func leftDragScrollsButAClickStaysAClick() {
        let (window, page, shelf) = makeWindow()
        let scroller = MiddleDragScroller()
        // A click (moving less than the threshold) goes through untouched.
        #expect(scroller.handle(mouse(.leftMouseDown, x: 300, y: 250, time: 1), in: window) != nil)
        #expect(scroller.handle(mouse(.leftMouseDragged, x: 303, y: 250, time: 1.1), in: window) != nil)
        let click = scroller.handle(mouse(.leftMouseUp, x: 303, y: 250, time: 1.2), in: window)
        #expect(click?.locationInWindow.x == 303)
        #expect(shelf.contentView.bounds.origin.x == 0)

        // Dragging sideways over the shelf scrolls it; letting go is no longer a click there.
        #expect(scroller.handle(mouse(.leftMouseDown, x: 300, y: 250, time: 2), in: window) != nil)
        #expect(scroller.handle(mouse(.leftMouseDragged, x: 250, y: 250, time: 2.5), in: window) == nil)
        #expect(scroller.handle(mouse(.leftMouseDragged, x: 200, y: 250, time: 3), in: window) == nil)
        let release = scroller.handle(mouse(.leftMouseUp, x: 200, y: 250, time: 4), in: window)
        #expect(shelf.contentView.bounds.origin.x == 100)
        #expect(release.map { window.contentView!.bounds.contains($0.locationInWindow) } == false)

        // Dragging up over the shelf scrolls the page instead.
        _ = scroller.handle(mouse(.leftMouseDown, x: 300, y: 210, time: 5), in: window)
        _ = scroller.handle(mouse(.leftMouseDragged, x: 300, y: 250, time: 5.5), in: window)
        _ = scroller.handle(mouse(.leftMouseDragged, x: 300, y: 290, time: 6), in: window)
        _ = scroller.handle(mouse(.leftMouseUp, x: 300, y: 290, time: 7), in: window)
        #expect(page.contentView.bounds.origin.y == 80)
        #expect(shelf.contentView.bounds.origin.x == 100)
    }

    @Test func aMiddleClickWithoutMovingDoesNothing() {
        let (window, page, shelf) = makeWindow()
        let scroller = MiddleDragScroller()
        _ = scroller.handle(mouse(.otherMouseDown, x: 300, y: 250, time: 1), in: window)
        _ = scroller.handle(mouse(.otherMouseDragged, x: 301, y: 250, time: 1.1), in: window)
        _ = scroller.handle(mouse(.otherMouseUp, x: 301, y: 250, time: 1.2), in: window)
        #expect(shelf.contentView.bounds.origin.x == 0)
        #expect(page.contentView.bounds.origin.y == 0)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
