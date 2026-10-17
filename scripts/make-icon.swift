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
ctx.setFillColor(color(0x18181B))
ctx.fillPath()
ctx.restoreGState()

// Background gradient: graphite
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [color(0x52525B), color(0x27272A), color(0x18181B)] as CFArray,
                    locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 180, y: 940), end: CGPoint(x: 860, y: 90), options: [])

// Soft highlight at the top
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [color(0xFFFFFF, 0.15), color(0xFFFFFF, 0)] as CFArray,
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

// Laptop with an incoming call on its screen
drawSymbol("laptopcomputer", pointSize: 400, weight: .semibold,
           in: CGRect(x: 160, y: 230, width: 704, height: 560),
           color: NSColor(red: 0.89, green: 0.89, blue: 0.91, alpha: 1), shadow: true)

let callCenter = CGPoint(x: 512, y: 516)
ctx.saveGState()
ctx.setStrokeColor(color(0xF97316, 0.55))
ctx.setLineWidth(14)
ctx.strokeEllipse(in: CGRect(x: callCenter.x - 108, y: callCenter.y - 108, width: 216, height: 216))
ctx.setFillColor(color(0xF97316))
ctx.fillEllipse(in: CGRect(x: callCenter.x - 86, y: callCenter.y - 86, width: 172, height: 172))
ctx.restoreGState()
drawSymbol("phone.fill", pointSize: 300, weight: .semibold,
           in: CGRect(x: callCenter.x - 52, y: callCenter.y - 52, width: 104, height: 104),
           color: .white, shadow: false)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Icon written to \(output)")
