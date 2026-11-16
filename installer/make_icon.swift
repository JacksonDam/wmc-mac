// Draws the installer's icon (a white disc on a blue squircle) as a 1024 px PNG.
//   swift make_icon.swift <out.png>
// Drawn from plain shapes: SF Symbols may not be used in app icons.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The macOS icon grid: an 824 px rounded square in the middle of 1024.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor(srgbRed: 0.08, green: 0.18, blue: 0.42, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.42, blue: 0.86, alpha: 1),
                    NSColor(srgbRed: 0.05, green: 0.16, blue: 0.42, alpha: 1)])!
    .draw(in: shape, angle: -90)

func circle(_ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: size / 2 - r, y: size / 2 - r, width: 2 * r, height: 2 * r))
}

// The disc: white with a soft sheen, a groove ring, and the hole showing the background.
let disc = circle(300)
disc.append(circle(52).reversed)
NSGraphicsContext.current?.saveGraphicsState()
let discShadow = NSShadow()
discShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
discShadow.shadowOffset = NSSize(width: 0, height: -8)
discShadow.shadowBlurRadius = 18
discShadow.set()
NSColor.white.setFill()
disc.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(srgbRed: 0.86, green: 0.91, blue: 0.98, alpha: 1),
                    NSColor(white: 1, alpha: 1), NSColor(srgbRed: 0.82, green: 0.88, blue: 0.97, alpha: 1)])!
    .draw(in: disc, angle: -35)
NSColor(srgbRed: 0.62, green: 0.72, blue: 0.88, alpha: 1).setStroke()
for (r, w) in [(118.0, 10.0), (230.0, 3.0), (300.0, 4.0)] as [(CGFloat, CGFloat)] {
    let ring = circle(r)
    ring.lineWidth = w
    ring.stroke()
}
let hole = circle(52)
hole.lineWidth = 6
hole.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
