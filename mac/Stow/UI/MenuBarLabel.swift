import AppKit
import SwiftUI

/// The menu bar icon; shows a dot while the Inbox has videos.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(nsImage: model.inbox.isEmpty ? MenuBarIcon.plain : MenuBarIcon.badged)
            .accessibilityLabel(model.inbox.isEmpty ? "Stow" : "Stow, \(model.inbox.count) new videos")
    }
}

/// Template images so the icon follows the menu bar's light/dark appearance.
@MainActor
private enum MenuBarIcon {
    static let plain = make(badged: false)
    static let badged = make(badged: true)

    private static func make(badged: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Stow")?
            .withSymbolConfiguration(config) else { return NSImage() }
        guard badged else {
            symbol.isTemplate = true
            return symbol
        }
        let dotSize: CGFloat = 6
        let size = NSSize(width: symbol.size.width + 2, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            let dot = NSRect(x: rect.maxX - dotSize, y: rect.maxY - dotSize, width: dotSize, height: dotSize)
            // Punch a gap around the dot so it reads as separate from the tray.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
