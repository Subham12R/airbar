// Renders README brand images into docs/brand/: the app icon, a logo, and a banner that shows
// a real panel screenshot. Usage: swift scripts/brand.swift <panel-screenshot.png>
import AppKit

let blue = NSColor(red: 0.2, green: 0.55, blue: 1, alpha: 1)
let ink = NSColor(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1b / 255.0, alpha: 1)
let out = URL(fileURLWithPath: "docs/brand", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func canvas(_ w: Int, _ h: Int, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func glyph(_ size: CGFloat, color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: "air.conditioner.horizontal.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}

func drawIcon(in rect: NSRect) {
    blue.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).fill()
    let g = glyph(rect.width * 0.46, color: .white)
    g.draw(in: NSRect(x: rect.midX - g.size.width / 2, y: rect.midY - g.size.height / 2, width: g.size.width, height: g.size.height))
}

// App icon (1024, with the macOS icon margin)
try canvas(1024, 1024) { drawIcon(in: NSRect(x: 100, y: 100, width: 824, height: 824)) }
    .write(to: out.appendingPathComponent("airbar-app-icon.png"))

// Logo: the icon without margin, for inline use
try canvas(256, 256) { drawIcon(in: NSRect(x: 0, y: 0, width: 256, height: 256)) }
    .write(to: out.appendingPathComponent("airbar-logo.png"))

// Banner: 2400 × 800
let screenshot = CommandLine.arguments.count > 1 ? NSImage(contentsOfFile: CommandLine.arguments[1]) : nil
try canvas(2400, 800) {
    ink.setFill()
    NSRect(x: 0, y: 0, width: 2400, height: 800).fill()
    drawIcon(in: NSRect(x: 160, y: 470, width: 150, height: 150))
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 132, weight: .bold), .foregroundColor: NSColor.white]
    NSAttributedString(string: "AirBar", attributes: title).draw(at: NSPoint(x: 345, y: 460))
    let tag: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 52, weight: .regular),
                                              .foregroundColor: NSColor(white: 0.72, alpha: 1)]
    NSAttributedString(string: "Your Hitachi air conditioner,", attributes: tag).draw(at: NSPoint(x: 165, y: 330))
    NSAttributedString(string: "from the Mac menu bar.", attributes: tag).draw(at: NSPoint(x: 165, y: 262))
    let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .medium),
                                                .foregroundColor: NSColor(white: 0.5, alpha: 1)]
    NSAttributedString(string: "Native SwiftUI · airCloud Go · Open source", attributes: small).draw(at: NSPoint(x: 168, y: 160))
    if let shot = screenshot {
        // Show the top of the panel (header, unit and temperature); the banner's bottom edge crops the rest.
        let w: CGFloat = 820
        let h = shot.size.height * w / shot.size.width
        let rect = NSRect(x: 2400 - w - 200, y: 800 - 90 - h, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 40
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        shot.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
} .write(to: out.appendingPathComponent("banner.png"))

print("Wrote docs/brand/airbar-app-icon.png, airbar-logo.png, banner.png")
