// Shared icon artwork (the HomeBar house): a white house on an orange rounded square.
// Prepended to make-icon.swift and brand.swift at run time, so both draw the same icon.
import AppKit

let iconOrange = NSColor(red: 1, green: 0.62, blue: 0.2, alpha: 1)

func symbol(_ name: String, _ size: CGFloat, _ color: NSColor, weight: NSFont.Weight = .semibold) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}

func drawIcon(in rect: NSRect) {
    iconOrange.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).fill()
    let house = symbol("house.fill", rect.width * 0.46, .white)
    let s = house.size
    house.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
}
