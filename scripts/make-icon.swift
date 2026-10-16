// Generates the PhoneBT app icon (1024×1024 PNG).
// Usage: swift scripts/make-icon.swift <output.png>

import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// macOS icon grid: 824pt body centered in 1024 canvas
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x0B3B4F))
ctx.fillPath()
ctx.restoreGState()

// Background gradient: deep indigo → teal
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [color(0x14E0A6), color(0x0F8FA8), color(0x2B2F8F)] as CFArray,
                    locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 180, y: 940), end: CGPoint(x: 860, y: 90), options: [])

// Soft highlight at the top
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 400, y: 880), startRadius: 0,
                       endCenter: CGPoint(x: 400, y: 880), endRadius: 520, options: [])

ctx.restoreGState()

// Symbols
func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, in rect: CGRect, color fill: NSColor, shadow: Bool) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [fill]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("Missing SF Symbol \(name)")
    }
    // Fit the symbol inside rect, preserving aspect ratio
    let s = image.size
    let scale = min(rect.width / s.width, rect.height / s.height)
    let drawn = CGSize(width: s.width * scale, height: s.height * scale)
    let origin = CGPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)

    ctx.saveGState()
    if shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x062033, 0.45))
    }
    image.draw(in: CGRect(origin: origin, size: drawn))
    ctx.restoreGState()
}

// Laptop (left) and iPhone (right)
drawSymbol("laptopcomputer", pointSize: 400, weight: .semibold,
           in: CGRect(x: 135, y: 215, width: 500, height: 390),
           color: .white, shadow: true)
drawSymbol("iphone", pointSize: 400, weight: .semibold,
           in: CGRect(x: 600, y: 215, width: 330, height: 460),
           color: .white, shadow: true)

// Link between them: dashed arc with a node at each end
let from = CGPoint(x: 385, y: 556)
let to = CGPoint(x: 765, y: 640)
let link = CGMutablePath()
link.move(to: from)
link.addCurve(to: to, control1: CGPoint(x: 410, y: 800), control2: CGPoint(x: 740, y: 850))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x062033, 0.35))
ctx.setStrokeColor(color(0xFFEE9E))
ctx.setLineWidth(20)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [2, 42])
ctx.addPath(link)
ctx.strokePath()
ctx.setFillColor(color(0xFFEE9E))
for point in [from, to] {
    ctx.fillEllipse(in: CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44))
}
ctx.restoreGState()

// Voice badge on the link
let badgeCenter = CGPoint(x: 575, y: 768)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x062033, 0.4))
ctx.setFillColor(color(0xFFEE9E))
ctx.fillEllipse(in: CGRect(x: badgeCenter.x - 78, y: badgeCenter.y - 78, width: 156, height: 156))
ctx.restoreGState()
drawSymbol("waveform", pointSize: 300, weight: .bold,
           in: CGRect(x: badgeCenter.x - 52, y: badgeCenter.y - 52, width: 104, height: 104),
           color: NSColor(red: 0.06, green: 0.36, blue: 0.5, alpha: 1), shadow: false)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Icon written to \(output)")
