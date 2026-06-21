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

    // Rounded gradient background (leave a small margin like a real app icon)
    let rect = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.045, dy: s * 0.045)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.33, green: 0.49, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.15, green: 0.23, blue: 0.64, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -90)

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
