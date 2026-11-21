import AppKit
import QuartzCore

/// One axis of a smooth scroll: eases `current` toward `target`, which each wheel notch moves.
struct ScrollGlide: Equatable {
    /// How quickly the scroll catches up; about 95% of the way after three time constants.
    static let timeConstant: TimeInterval = 0.07
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

/// Makes scrolling in Stow's windows faster (settings › Scrolling) and lets notched mouse wheels
/// glide instead of jumping. Trackpads and smooth-scrolling mice keep their own feel and only
/// get the speed. Works on every AppKit/SwiftUI scroll view, since all are NSScrollViews.
@MainActor
final class ScrollEngine: NSObject {
    static let shared = ScrollEngine()

    override init() { super.init() }

    /// macOS's distance per wheel line when a scroll view doesn't say (points).
    static let defaultLineHeight: CGFloat = 10

    private var monitor: Any?
    private var settings: () -> ScrollSettings = { .default }
    private var glide: Glide?

    private struct Glide {
        weak var scrollView: NSScrollView?
        var x: ScrollGlide
        var y: ScrollGlide
        /// What this glide last set, to notice when something else (the scroller) moved the view.
        var lastSet: CGPoint
        var link: CADisplayLink
        var lastTimestamp: CFTimeInterval?
    }

    /// Starts handling scroll events for the app; `settings` is read on every event.
    func install(settings: @escaping () -> ScrollSettings) {
        use(settings)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    func use(_ settings: @escaping () -> ScrollSettings) {
        self.settings = settings
    }

    /// Returns the event to deliver, or nil when the engine scrolled itself. `window` is for tests,
    /// whose synthesized events have none.
    func handle(_ event: NSEvent, in window: NSWindow? = nil) -> NSEvent? {
        let settings = settings()
        let isWheel = !event.hasPreciseScrollingDeltas
        guard isWheel, settings.smooth else {
            stopGlide()
            return settings.speed == 1 ? event : Self.scaled(event, by: settings.speed)
        }
        guard let scrollView = Self.scrollView(for: event, in: window ?? event.window) else { return event }
        let lineHeight = Self.lineHeight(of: scrollView)
        // A positive delta scrolls toward the top/left, as macOS reports it (natural scrolling included).
        let dx = -event.scrollingDeltaX * lineHeight * settings.speed
        let dy = -event.scrollingDeltaY * lineHeight * settings.speed
        glide(scrollView, dx: dx, dy: dy)
        return nil
    }

    // MARK: Gliding

    private func glide(_ scrollView: NSScrollView, dx: CGFloat, dy: CGFloat) {
        let clip = scrollView.contentView
        let origin = clip.bounds.origin
        if glide?.scrollView !== scrollView || glide.map({ Self.moved(clip, from: $0.lastSet) }) == true {
            stopGlide()
        }
        if glide == nil {
            let link = scrollView.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            glide = Glide(scrollView: scrollView, x: ScrollGlide(at: origin.x), y: ScrollGlide(at: origin.y),
                          lastSet: origin, link: link)
        }
        let flip: CGFloat = scrollView.documentView?.isFlipped == false ? -1 : 1
        let range = Self.scrollableRange(of: clip)
        glide?.x.add(dx, within: range.x)
        glide?.y.add(dy * flip, within: range.y)
    }

    @objc private func frame(_ link: CADisplayLink) {
        let elapsed = glide?.lastTimestamp.map { link.targetTimestamp - $0 } ?? link.duration
        glide?.lastTimestamp = link.targetTimestamp
        advance(by: elapsed)
    }

    /// Moves the gliding scroll view one frame on; tests call it directly.
    func advance(by elapsed: TimeInterval) {
        guard var glide, let scrollView = glide.scrollView else { return stopGlide() }
        let clip = scrollView.contentView
        // The user grabbed the scroller or something else scrolled: let go.
        if Self.moved(clip, from: glide.lastSet) { return stopGlide() }
        let point = CGPoint(x: glide.x.step(elapsed: elapsed), y: glide.y.step(elapsed: elapsed))
        clip.scroll(to: point)
        scrollView.reflectScrolledClipView(clip)
        glide.lastSet = clip.bounds.origin
        self.glide = glide
        if glide.x.isSettled, glide.y.isSettled { stopGlide() }
    }

    var isGliding: Bool { glide != nil }

    func stopGlide() {
        glide?.link.invalidate()
        glide = nil
    }

    private static func moved(_ clip: NSClipView, from point: CGPoint) -> Bool {
        let origin = clip.bounds.origin
        return abs(origin.x - point.x) > 1 || abs(origin.y - point.y) > 1
    }

    // MARK: Scroll views

    /// The innermost scroll view under the pointer that can scroll the way the wheel turned, so a
    /// vertical turn over a horizontal shelf scrolls the page.
    private static func scrollView(for event: NSEvent, in window: NSWindow?) -> NSScrollView? {
        guard let content = window?.contentView else { return nil }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        let vertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        var view = content.hitTest(point)
        while let current = view {
            if let scrollView = current as? NSScrollView, canScroll(scrollView, vertically: vertical) {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }

    private static func canScroll(_ scrollView: NSScrollView, vertically: Bool) -> Bool {
        let range = scrollableRange(of: scrollView.contentView)
        let extent = vertically ? range.y : range.x
        return extent.upperBound - extent.lowerBound > 1
    }

    /// Where the clip view's origin may go, per axis (content insets included).
    private static func scrollableRange(of clip: NSClipView) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        let bounds = clip.bounds
        let far = clip.constrainBoundsRect(NSRect(origin: CGPoint(x: 1e9, y: 1e9), size: bounds.size)).origin
        let near = clip.constrainBoundsRect(NSRect(origin: CGPoint(x: -1e9, y: -1e9), size: bounds.size)).origin
        return (min(near.x, far.x)...max(near.x, far.x), min(near.y, far.y)...max(near.y, far.y))
    }

    private static func lineHeight(of scrollView: NSScrollView) -> CGFloat {
        let line = scrollView.verticalLineScroll
        return line > 0 ? min(line, 60) : defaultLineHeight
    }

    // MARK: Speed only

    /// The same event with its distances multiplied (trackpads, or wheels with gliding off).
    private static func scaled(_ event: NSEvent, by factor: Double) -> NSEvent {
        guard let copy = event.cgEvent?.copy() else { return event }
        let fixedFields: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
        for field in fixedFields {
            copy.setDoubleValueField(field, value: copy.getDoubleValueField(field) * factor)
        }
        let intFields: [CGEventField] = [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                                         .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2]
        for field in intFields {
            let value = copy.getIntegerValueField(field)
            copy.setIntegerValueField(field, value: Int64((Double(value) * factor).rounded()))
        }
        return NSEvent(cgEvent: copy) ?? event
    }
}
