#!/usr/bin/env swift
// Draws the app icon and writes Resources/AppIcon.icns and docs/icon.png.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

/// Drawn on a 1024pt canvas (macOS icon grid: 824pt body, 100pt margin for the shadow).
func drawIcon() {
    // Body: warm sticky-note gradient with the standard drop shadow.
    let body = roundedRect(100, 100, 824, 824, 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0xFFC83D).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xFFE47A), ending: color(0xFFB21E))!.draw(in: body, angle: -90)

    // Note card.
    NSGraphicsContext.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = color(0x8A5A00, 0.30)
    cardShadow.shadowBlurRadius = 20
    cardShadow.shadowOffset = NSSize(width: 0, height: -8)
    cardShadow.set()
    color(0xFFFDF7).setFill()
    roundedRect(262, 236, 500, 560, 48).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Text lines.
    color(0xD8CFBF).setFill()
    roundedRect(330, 676, 364, 34, 17).fill()
    roundedRect(330, 610, 280, 34, 17).fill()

    // Code box with a copy glyph — the app's signature feature.
    color(0x33312C).setFill()
    roundedRect(318, 438, 388, 104, 24).fill()
    color(0xFFD45C).setFill()
    for (x, width) in [(350.0, 70.0), (434.0, 48.0), (496.0, 90.0)] {
        roundedRect(x, 478, width, 24, 12).fill()
    }
    color(0xFFFDF7, 0.9).setStroke()
    let back = roundedRect(640, 482, 30, 36, 7)
    back.lineWidth = 7
    back.stroke()
    color(0x33312C).setFill()
    let front = roundedRect(628, 468, 30, 36, 7)
    front.fill()
    front.lineWidth = 7
    front.stroke()

    color(0xD8CFBF).setFill()
    roundedRect(330, 330, 220, 34, 17).fill()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try fm.createDirectory(atPath: "docs", withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try png(size: 512).write(to: URL(fileURLWithPath: "docs/icon.png"))
try? fm.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns and docs/icon.png")
