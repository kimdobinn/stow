// Renders the 1024px app icon: swift scripts/make-icon.swift icon-1024.png (then resize into AppIcon.appiconset with sips).
import AppKit
let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
    NSColor.black.setFill(); path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // Paper: a terracotta screen with a cream play button on cream (the phone's icon is the same).
    let cream = NSColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF5 / 255, alpha: 1)
    let terracotta = NSColor(srgbRed: 0xC9 / 255, green: 0x64 / 255, blue: 0x42 / 255, alpha: 1)
    cream.setFill(); path.fill()
    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08).setStroke()
    path.lineWidth = 3; path.stroke()
    // Laid out on a 100-unit grid over the body (y up).
    let unit = rect.width / 100
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * unit, y: rect.maxY - y * unit) }
    let screen = NSBezierPath(roundedRect: NSRect(x: rect.minX + 15 * unit, y: rect.maxY - 73 * unit, width: 70 * unit, height: 46 * unit),
                              xRadius: 15 * unit, yRadius: 15 * unit)
    terracotta.setFill(); screen.fill()
    let play = NSBezierPath()
    play.move(to: point(44, 39)); play.line(to: point(44, 61)); play.line(to: point(61, 50)); play.close()
    play.lineJoinStyle = .round; play.lineWidth = 4 * unit
    cream.setFill(); cream.setStroke(); play.fill(); play.stroke()
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
