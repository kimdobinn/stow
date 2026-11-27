// ios/scripts/make-icon.swift <output.png>: Stow/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
// Renders Stow's icon full-bleed for iOS (no alpha), from the Android adaptive icon's geometry:
// a 108-unit canvas whose visible part is the middle 72 units.
import AppKit
import CoreGraphics

let size = 1024.0
let scale = size / 72.0
func p(_ v: Double) -> Double { (v - 18.0) * scale }
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Flip so y grows downwards, as in the vector.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)
let cream = CGColor(srgbRed: 0xFA/255.0, green: 0xF9/255.0, blue: 0xF5/255.0, alpha: 1)
let terracotta = CGColor(srgbRed: 0xC9/255.0, green: 0x64/255.0, blue: 0x42/255.0, alpha: 1)
ctx.setFillColor(cream)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
let screen = CGRect(x: p(28.8), y: p(37.44), width: (79.2 - 28.8) * scale, height: (70.56 - 37.44) * scale)
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 10.8 * scale, cornerHeight: 10.8 * scale, transform: nil))
ctx.setFillColor(terracotta)
ctx.fillPath()
let triangle = CGMutablePath()
triangle.move(to: CGPoint(x: p(49.68), y: p(46.08)))
triangle.addLine(to: CGPoint(x: p(49.68), y: p(61.92)))
triangle.addLine(to: CGPoint(x: p(61.92), y: p(54)))
triangle.closeSubpath()
ctx.addPath(triangle)
ctx.setFillColor(cream)
ctx.setStrokeColor(cream)
ctx.setLineWidth(2.88 * scale)
ctx.setLineJoin(.round)
ctx.drawPath(using: .fillStroke)
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
