// Renders README brand images into docs/brand/: app icon, logo, and a banner with real screenshots.
// Usage: scripts/brand.sh <ac-panel.png> <lights-panel.png>   (icon-art.swift is prepended at run time)
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

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: NSPoint) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: p)
}

func screenshot(_ img: NSImage, width w: CGFloat, topAt top: CGFloat, x: CGFloat) {
    let h = img.size.height * w / img.size.width
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    img.draw(in: NSRect(x: x, y: top - h, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
}

// App icon (1024, with the macOS icon margin) and logo (no margin)
try canvas(1024, 1024) { drawIcon(in: NSRect(x: 100, y: 100, width: 824, height: 824)) }.write(to: out.appendingPathComponent("airbar-app-icon.png"))
try canvas(256, 256) { drawIcon(in: NSRect(x: 0, y: 0, width: 256, height: 256)) }.write(to: out.appendingPathComponent("airbar-logo.png"))

// Banner 2400 × 800: name and tagline on the left, the AC and lights panels on the right
let args = CommandLine.arguments
let ac = args.count > 1 ? NSImage(contentsOfFile: args[1]) : nil
let lights = args.count > 2 ? NSImage(contentsOfFile: args[2]) : nil
try canvas(2400, 800) {
    ink.setFill()
    NSRect(x: 0, y: 0, width: 2400, height: 800).fill()
    drawIcon(in: NSRect(x: 150, y: 480, width: 150, height: 150))
    text("AirBar", 132, .bold, .white, at: NSPoint(x: 335, y: 470))
    text("Your home, from the", 56, .regular, NSColor(white: 0.75, alpha: 1), at: NSPoint(x: 155, y: 345))
    text("Mac menu bar.", 56, .regular, NSColor(white: 0.75, alpha: 1), at: NSPoint(x: 155, y: 272))
    text("Hitachi AC  ·  HomeMate & Tuya lights  ·  Open source", 32, .medium, NSColor(white: 0.5, alpha: 1), at: NSPoint(x: 158, y: 170))
    if let lights { screenshot(lights, width: 600, topAt: 740, x: 1690) }
    if let ac { screenshot(ac, width: 600, topAt: 700, x: 1040) }
}.write(to: out.appendingPathComponent("banner.png"))

print("Wrote docs/brand/airbar-app-icon.png, airbar-logo.png, banner.png")
