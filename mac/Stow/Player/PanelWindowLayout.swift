import CoreGraphics

/// Where the main window goes when the player panel is added to its right, and back.
enum PanelWindowLayout {
    /// `window` widened by `grow` to the right, kept on `visible` (moved left, then narrowed, when
    /// it doesn't fit).
    static func grownFrame(window: CGRect, visible: CGRect, grow: CGFloat) -> CGRect {
        let width = min(window.width + max(grow, 0), max(visible.width, window.width))
        var x = window.minX
        if x + width > visible.maxX { x = max(visible.minX, visible.maxX - width) }
        return CGRect(x: x, y: window.minY, width: width, height: window.height)
    }

    /// The window once the panel is gone: back where it was when nobody moved or resized it while
    /// the panel was open, otherwise `shrink` narrower, keeping its left edge.
    static func shrunkFrame(current: CGRect, grown: CGRect, original: CGRect,
                            shrink: CGFloat, minWidth: CGFloat) -> CGRect {
        // The window server may round the animated frame by a point.
        let untouched = abs(current.minX - grown.minX) < 2 && abs(current.minY - grown.minY) < 2
            && abs(current.width - grown.width) < 2 && abs(current.height - grown.height) < 2
        if untouched { return original }
        let width = max(current.width - max(shrink, 0), minWidth)
        return CGRect(x: current.minX, y: current.minY, width: width, height: current.height)
    }
}
