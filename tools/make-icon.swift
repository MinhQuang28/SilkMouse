import AppKit

// Generates Resources/AppIcon.icns — a mouse glyph on a blue gradient rounded square.
// Run: swift tools/make-icon.swift   (from the project root)

let iconset = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)

func renderPNG(_ px: Int) -> Data {
    let s = CGFloat(px)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // Rounded satin background (leave a small margin like a real app icon): deep indigo →
    // violet, lit diagonally like sheened silk.
    let rect = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.045, dy: s * 0.045)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.62, green: 0.35, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.26, green: 0.14, blue: 0.58, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -70)

    // Silk ribbon: a band of translucent S-curves sweeping behind the glyph — the smooth-scroll
    // wave the app is named for. Clipped to the rounded square.
    NSGraphicsContext.current?.saveGraphicsState()
    bg.setClip()
    for (offset, alpha, width) in [(-0.07, 0.16, 0.050), (0.0, 0.28, 0.040), (0.06, 0.14, 0.030)] {
        let path = NSBezierPath()
        let y = s * (0.30 + offset)
        path.move(to: NSPoint(x: rect.minX - s * 0.05, y: y))
        path.curve(to: NSPoint(x: rect.maxX + s * 0.05, y: y + s * 0.34),
                   controlPoint1: NSPoint(x: s * 0.38, y: y - s * 0.18),
                   controlPoint2: NSPoint(x: s * 0.62, y: y + s * 0.52))
        path.lineWidth = s * width
        path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // White mouse glyph, centered
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.52, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
    if let glyph = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let g = glyph.size
        glyph.draw(in: NSRect(x: (s - g.width) / 2, y: (s - g.height) / 2, width: g.width, height: g.height))
    }

    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
}

// iconset entries → pixel size
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
var cache: [Int: Data] = [:]
for (name, px) in entries {
    let data = cache[px] ?? renderPNG(px)
    cache[px] = data
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

// Build the .icns
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ Resources/AppIcon.icns" : "✗ iconutil failed (\(p.terminationStatus))")
