import AppKit
import QuartzCore
import SwiftUI

/// Drag to scroll, with the middle mouse button (the wheel) or the left one: the content follows
/// the pointer, along the drag's direction (sideways over the Inbox's shelves, else down the page),
/// and keeps gliding a little after letting go.
///
/// A left press still goes through as a click; only once the pointer has moved does it become a
/// scroll, and then letting go no longer counts as a click on what's under it. Places where a left
/// drag means something else keep it: sliders, scroll bars, tables and lists, text, and views marked
/// `.noDragScroll()` (the Inbox's shelf headers, which drag to reorder).
///
/// Wheel scrolling itself can't be changed from inside the app: SwiftUI's scroll views take wheel
/// events before an event monitor could replace them, so speed and smoothing are left to the system.
@MainActor
final class MiddleDragScroller: NSObject {
    static let shared = MiddleDragScroller()

    /// Movement under this many points is a middle click, not a drag.
    static let dragThreshold: CGFloat = 3
    /// A left press has to move further before it scrolls, so a slightly shaky click stays a click.
    static let leftDragThreshold: CGFloat = 6
    /// How far the glide after letting go travels, in seconds of the release speed.
    static let flingTime: TimeInterval = 0.18

    private var monitor: Any?
    private var drag: Drag?
    private var fling: Fling?
    /// Views where a left drag keeps its own meaning (`.noDragScroll()`).
    let exclusions = NSHashTable<NSView>.weakObjects()

    private enum Button { case left, middle }

    private struct Drag {
        var button: Button
        /// The scroll views under the pointer, innermost first, with the directions each scrolls.
        var candidates: [(scrollView: NSScrollView, horizontal: Bool, vertical: Bool)]
        weak var scrollView: NSScrollView?
        var horizontal = false
        var vertical = false
        var start: CGPoint
        var isDragging = false
        /// Recent pointer positions (window points) with times, for the release speed.
        var samples: [(point: CGPoint, time: TimeInterval)] = []
    }

    private struct Fling {
        weak var scrollView: NSScrollView?
        var x: ScrollGlide
        var y: ScrollGlide
        var link: CADisplayLink
        var lastTimestamp: CFTimeInterval?
    }

    override init() { super.init() }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp,
                                                              .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    /// Returns the event to deliver, or nil when it was used for dragging. `window` is for tests,
    /// whose synthesized events have none.
    func handle(_ event: NSEvent, in window: NSWindow? = nil) -> NSEvent? {
        guard let window = window ?? event.window else { return event }
        let point = event.locationInWindow
        switch event.type {
        case .otherMouseDown:
            guard event.buttonNumber == 2 else { return event }
            stopFling()
            let candidates = Self.scrollViews(at: point, in: window)
            guard !candidates.isEmpty else { return event }
            drag = Drag(button: .middle, candidates: candidates, start: point, samples: [(point, event.timestamp)])
            return nil
        case .leftMouseDown:
            drag = nil
            stopFling()
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                  !isExcluded(point, in: window) else { return event }
            let candidates = Self.scrollViews(at: point, in: window)
            if !candidates.isEmpty {
                drag = Drag(button: .left, candidates: candidates, start: point, samples: [(point, event.timestamp)])
            }
            return event
        case .otherMouseDragged, .leftMouseDragged:
            guard var drag, drag.button == (event.type == .leftMouseDragged ? .left : .middle),
                  let last = drag.samples.last else { return event }
            let threshold = drag.button == .left ? Self.leftDragThreshold : Self.dragThreshold
            let wasDragging = drag.isDragging
            if !drag.isDragging, hypot(point.x - drag.start.x, point.y - drag.start.y) >= threshold {
                guard let chosen = Self.choose(drag.candidates, dx: point.x - drag.start.x, dy: point.y - drag.start.y) else {
                    self.drag = nil
                    return event
                }
                drag.scrollView = chosen.scrollView
                drag.horizontal = chosen.horizontal
                drag.vertical = chosen.vertical
                drag.isDragging = true
                NSCursor.closedHand.push()
            }
            if drag.isDragging, let scrollView = drag.scrollView {
                // The first step catches up with everything since the press.
                let from = wasDragging ? last.point : drag.start
                move(scrollView, by: CGPoint(x: point.x - from.x, y: point.y - from.y), drag: drag)
            }
            drag.samples = (drag.samples + [(point, event.timestamp)]).filter { event.timestamp - $0.time < 0.1 }
            self.drag = drag
            // A left press that hasn't become a scroll yet still belongs to what's under it.
            return drag.button == .left && !drag.isDragging ? event : nil
        case .otherMouseUp, .leftMouseUp:
            guard let drag, drag.button == (event.type == .leftMouseUp ? .left : .middle) else { return event }
            self.drag = nil
            guard drag.isDragging else { return drag.button == .left ? event : nil }
            NSCursor.pop()
            if let scrollView = drag.scrollView { startFling(scrollView, drag: drag, releasedAt: event.timestamp) }
            return drag.button == .left ? Self.cancelledClick(event) : nil
        default:
            return event
        }
    }

    /// The same release far outside the window, so the button that was pressed doesn't act on it.
    private static func cancelledClick(_ event: NSEvent) -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: -100_000, y: -100_000), modifierFlags: event.modifierFlags,
                           timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                           eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: 0)
    }

    /// The innermost scroll view that scrolls along the drag: sideways for a sideways drag, else down.
    private static func choose(_ candidates: [(scrollView: NSScrollView, horizontal: Bool, vertical: Bool)],
                               dx: CGFloat, dy: CGFloat) -> (scrollView: NSScrollView, horizontal: Bool, vertical: Bool)? {
        let sideways = abs(dx) >= abs(dy)
        return candidates.first(where: { sideways ? $0.horizontal : $0.vertical })
            ?? candidates.first(where: { sideways ? $0.vertical : $0.horizontal })
    }

    /// A left drag starting here isn't a scroll: controls that drag themselves, text, marked views.
    private func isExcluded(_ point: CGPoint, in window: NSWindow) -> Bool {
        if exclusions.allObjects.contains(where: { view in
            view.window === window && view.convert(view.bounds, to: nil).contains(point)
        }) { return true }
        guard let content = window.contentView else { return false }
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let current = view {
            if current is NSScroller || current is NSSlider || current is NSTableView || current is NSText
                || (current as? NSTextField).map({ $0.isEditable || $0.isSelectable }) == true {
                return true
            }
            if current is NSScrollView { return false }
            view = current.superview
        }
        return false
    }

    // MARK: Moving

    /// Moves the content with the pointer: dragging right reveals what's on the left.
    private func move(_ scrollView: NSScrollView, by pointer: CGPoint, drag: Drag) {
        var origin = scrollView.contentView.bounds.origin
        // Window points grow upward; a flipped document's offsets grow downward.
        let flipped = scrollView.documentView?.isFlipped != false
        if drag.horizontal { origin.x -= pointer.x }
        if drag.vertical { origin.y += flipped ? pointer.y : -pointer.y }
        scroll(scrollView, to: origin)
    }

    private func scroll(_ scrollView: NSScrollView, to point: CGPoint) {
        let clip = scrollView.contentView
        let range = Self.scrollableRange(of: clip)
        let clamped = CGPoint(x: min(max(point.x, range.x.lowerBound), range.x.upperBound),
                              y: min(max(point.y, range.y.lowerBound), range.y.upperBound))
        clip.scroll(to: clamped)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Fling

    private func startFling(_ scrollView: NSScrollView, drag: Drag, releasedAt time: TimeInterval) {
        // Only a drag still moving when let go keeps going.
        guard let first = drag.samples.first, let last = drag.samples.last, last.time - first.time > 0.005,
              time - last.time < 0.05 else { return }
        let seconds = last.time - first.time
        let velocity = CGPoint(x: (last.point.x - first.point.x) / seconds, y: (last.point.y - first.point.y) / seconds)
        let origin = scrollView.contentView.bounds.origin
        let flipped = scrollView.documentView?.isFlipped != false
        let range = Self.scrollableRange(of: scrollView.contentView)
        var x = ScrollGlide(at: origin.x)
        var y = ScrollGlide(at: origin.y)
        if drag.horizontal { x.add(-velocity.x * Self.flingTime, within: range.x) }
        if drag.vertical { y.add((flipped ? velocity.y : -velocity.y) * Self.flingTime, within: range.y) }
        guard !x.isSettled || !y.isSettled else { return }
        let link = scrollView.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        fling = Fling(scrollView: scrollView, x: x, y: y, link: link)
    }

    @objc private func frame(_ link: CADisplayLink) {
        let elapsed = fling?.lastTimestamp.map { link.targetTimestamp - $0 } ?? link.duration
        fling?.lastTimestamp = link.targetTimestamp
        advanceFling(by: elapsed)
    }

    /// One frame of the glide after letting go; tests call it directly.
    func advanceFling(by elapsed: TimeInterval) {
        guard var fling, let scrollView = fling.scrollView else { return stopFling() }
        scroll(scrollView, to: CGPoint(x: fling.x.step(elapsed: elapsed), y: fling.y.step(elapsed: elapsed)))
        self.fling = fling
        if fling.x.isSettled, fling.y.isSettled { stopFling() }
    }

    var isFlinging: Bool { fling != nil }

    private func stopFling() {
        fling?.link.invalidate()
        fling = nil
    }

    // MARK: Scroll views

    /// The scroll views under `point` that can scroll, innermost first, with their directions.
    private static func scrollViews(at point: CGPoint, in window: NSWindow) -> [(scrollView: NSScrollView, horizontal: Bool, vertical: Bool)] {
        guard let content = window.contentView else { return [] }
        let local = content.superview?.convert(point, from: nil) ?? point
        var candidates: [(scrollView: NSScrollView, horizontal: Bool, vertical: Bool)] = []
        var view = content.hitTest(local)
        while let current = view {
            if let scrollView = current as? NSScrollView {
                let range = scrollableRange(of: scrollView.contentView)
                let horizontal = range.x.upperBound - range.x.lowerBound > 1
                let vertical = range.y.upperBound - range.y.lowerBound > 1
                if horizontal || vertical { candidates.append((scrollView, horizontal, vertical)) }
            }
            view = current.superview
        }
        return candidates
    }

    /// Where the clip view's origin may go, per axis (content insets included).
    static func scrollableRange(of clip: NSClipView) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        let size = clip.bounds.size
        let far = clip.constrainBoundsRect(NSRect(origin: CGPoint(x: 1e9, y: 1e9), size: size)).origin
        let near = clip.constrainBoundsRect(NSRect(origin: CGPoint(x: -1e9, y: -1e9), size: size)).origin
        return (min(near.x, far.x)...max(near.x, far.x), min(near.y, far.y)...max(near.y, far.y))
    }
}

/// One axis of an eased scroll: moves `current` toward `target`.
struct ScrollGlide: Equatable {
    /// How quickly the scroll catches up; about 95% of the way after three time constants.
    static let timeConstant: TimeInterval = 0.12
    /// Closer than this (points), the scroll lands on the target.
    static let settleDistance: CGFloat = 0.5

    var current: CGFloat
    var target: CGFloat

    init(at position: CGFloat) {
        current = position
        target = position
    }

    var isSettled: Bool { abs(target - current) < Self.settleDistance }

    /// Moves the target by `delta`, kept within `range` (the scrollable extent).
    mutating func add(_ delta: CGFloat, within range: ClosedRange<CGFloat>) {
        target = min(max(target + delta, range.lowerBound), range.upperBound)
    }

    /// Advances by `elapsed` seconds and returns the new position.
    mutating func step(elapsed: TimeInterval) -> CGFloat {
        let fraction = 1 - exp(-max(elapsed, 0) / Self.timeConstant)
        current += (target - current) * CGFloat(fraction)
        if isSettled { current = target }
        return current
    }
}

/// Marks a view where a left drag keeps its own meaning instead of scrolling (see MiddleDragScroller).
private struct NoDragScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated {
                if window == nil { MiddleDragScroller.shared.exclusions.remove(self) }
                else { MiddleDragScroller.shared.exclusions.add(self) }
            }
        }
    }
}

extension View {
    /// A left drag here doesn't scroll (it reorders, selects text, …).
    func noDragScroll() -> some View { background(NoDragScroll()) }
}
