import AppKit
import QuartzCore

/// Hold the middle mouse button (the wheel) and drag to scroll: the content follows the pointer,
/// sideways first (the Inbox's shelves), and keeps gliding a little after letting go.
///
/// Wheel scrolling itself can't be changed from inside the app: SwiftUI's scroll views take wheel
/// events before an event monitor could replace them, so speed and smoothing are left to the system.
@MainActor
final class MiddleDragScroller: NSObject {
    static let shared = MiddleDragScroller()

    /// Movement under this many points is a middle click, not a drag.
    static let dragThreshold: CGFloat = 3
    /// How far the glide after letting go travels, in seconds of the release speed.
    static let flingTime: TimeInterval = 0.18

    private var monitor: Any?
    private var drag: Drag?
    private var fling: Fling?

    private struct Drag {
        weak var scrollView: NSScrollView?
        var horizontal: Bool
        var vertical: Bool
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    /// Returns the event to deliver, or nil when it was used for dragging. `window` is for tests,
    /// whose synthesized events have none.
    func handle(_ event: NSEvent, in window: NSWindow? = nil) -> NSEvent? {
        guard event.buttonNumber == 2, let window = window ?? event.window else { return event }
        let point = event.locationInWindow
        switch event.type {
        case .otherMouseDown:
            stopFling()
            guard let found = Self.scrollView(at: point, in: window) else { return event }
            drag = Drag(scrollView: found.scrollView, horizontal: found.horizontal, vertical: found.vertical,
                        start: point, samples: [(point, event.timestamp)])
            return nil
        case .otherMouseDragged:
            guard var drag, let scrollView = drag.scrollView, let last = drag.samples.last else { return event }
            if !drag.isDragging, hypot(point.x - drag.start.x, point.y - drag.start.y) >= Self.dragThreshold {
                drag.isDragging = true
                NSCursor.closedHand.push()
            }
            if drag.isDragging {
                move(scrollView, by: CGPoint(x: point.x - last.point.x, y: point.y - last.point.y), drag: drag)
            }
            drag.samples = (drag.samples + [(point, event.timestamp)]).filter { event.timestamp - $0.time < 0.1 }
            self.drag = drag
            return nil
        case .otherMouseUp:
            guard let drag else { return event }
            self.drag = nil
            guard drag.isDragging else { return nil }
            NSCursor.pop()
            if let scrollView = drag.scrollView { startFling(scrollView, drag: drag, releasedAt: event.timestamp) }
            return nil
        default:
            return event
        }
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

    /// The innermost scroll view under `point` that can scroll sideways, else the innermost that
    /// can scroll at all, with the directions it scrolls.
    private static func scrollView(at point: CGPoint, in window: NSWindow) -> (scrollView: NSScrollView, horizontal: Bool, vertical: Bool)? {
        guard let content = window.contentView else { return nil }
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
        return candidates.first(where: \.horizontal) ?? candidates.first
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
