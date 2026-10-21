import SwiftUI
import TuyaKit

/// Lights and switches in the panel: a tile per switch, and a card per light.
struct LightsSection: View {
    @Environment(Store.self) var store
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    private var tiles: [(key: String, device: TuyaDevice, toggle: TuyaDevice.Toggle)] {
        store.devices.flatMap { d in d.toggles.map { ("\(d.id)#\($0.dp)", d, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lights & switches").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(store.switchesOn) on").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: columns, spacing: 8) {
                // Keyed by device + data point: two lights can both use DP 20.
                ForEach(tiles, id: \.key) { tile in SwitchTile(device: tile.device, toggle: tile.toggle) }
            }
            ForEach(store.devices.filter { $0.isLight && ($0.hasBrightness || $0.hasColour) }) { d in
                if store.deviceStates[d.id]?.online != false { LightCard(device: d) }
            }
        }
    }
}

enum LightColor {
    /// What the light looks like now: its colour, or a warm/cool white.
    static func of(_ l: LightState?) -> Color {
        guard let l, l.on else { return Color(white: 0.6) }
        if l.mode == "colour", let h = l.hue { return Color(hue: Double(h) / 360, saturation: 0.75, brightness: 1) }
        // Saturated enough to read in light and dark mode: cool blue → warm amber.
        let w = Double(l.warmth ?? 70) / 100
        return Color(red: 0.45 + 0.55 * w, green: 0.66 - 0.04 * w, blue: 1 - 0.8 * w)
    }
}

struct BulbGlyph: View {
    var on: Bool
    var color: Color
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: on ? "lightbulb.fill" : "lightbulb")
            .font(.system(size: size * 0.6, weight: .medium))
            .foregroundStyle(on ? color : .secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(on ? color.opacity(0.2) : Color.primary.opacity(0.06)))
            .animation(.smooth(duration: 0.3), value: on)
    }
}

struct SwitchTile: View {
    @Environment(Store.self) var store
    let device: TuyaDevice
    let toggle: TuyaDevice.Toggle

    private var state: DeviceState? { store.deviceStates[device.id] }
    private var on: Bool { state?.toggles[toggle.dp] ?? false }
    private var online: Bool { state?.online ?? true }
    private var multi: Bool { device.toggles.count > 1 }
    private var icon: String {
        let n = (toggle.name + " " + device.name).lowercased()
        if device.isLight { return "lightbulb.fill" }
        if n.contains("fan") { return "fanblades.fill" }
        if n.contains("socket") || n.contains("plug") { return "powerplug.fill" }
        if n.contains("tv") { return "tv.fill" }
        if device.isLight || n.contains("light") || n.contains("lamp") { return "lightbulb.fill" }
        return "power"
    }
    private var tint: Color { device.isLight ? LightColor.of(state?.light) : Theme.warm }

    var body: some View {
        Button { store.toggle(device, dp: toggle.dp) } label: {
            HStack(spacing: 9) {
                if icon == "lightbulb.fill" {
                    BulbGlyph(on: on, color: tint)
                } else {
                    Image(systemName: online ? icon : "wifi.exclamationmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? tint : .secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(on ? tint.opacity(0.2) : Color.primary.opacity(0.06)))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(multi ? toggle.name : device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(!online ? "Unreachable" : (multi ? device.name : (on ? "On" : "Off")))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.busyDevices.contains(device.id) { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .card(12, tint: on ? tint : nil)
        .opacity(online ? 1 : 0.5)
        .disabled(!online)
        .help(state?.error ?? (on ? "Turn off" : "Turn on"))
        .animation(.smooth(duration: 0.25), value: on)
    }
}

struct LightCard: View {
    @Environment(Store.self) var store
    let device: TuyaDevice
    @State private var brightness: Double = 50
    @State private var warmth: Double = 50

    static let swatches: [(String, Int)] = [("Red", 0), ("Orange", 28), ("Yellow", 52), ("Green", 125),
                                            ("Cyan", 185), ("Blue", 225), ("Purple", 275), ("Pink", 320)]

    private var light: LightState? { store.deviceStates[device.id]?.light }
    private var on: Bool { light?.on ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { if let p = device.powerDP { store.toggle(device, dp: p) } } label: {
                    BulbGlyph(on: on, color: LightColor.of(light), size: 34)
                }
                .buttonStyle(Pressable())
                .help(on ? "Turn off" : "Turn on")
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(size: 13, weight: .semibold))
                    Text(on ? "\(Int(brightness))% · \(light?.mode == "colour" ? "Colour" : "White")" : "Off")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if device.hasBrightness {
                TrackSlider(value: $brightness, icon: "sun.max.fill", fill: Theme.warm) { store.setBrightness(device, Int($0)) }
            }
            if device.hasWarmth {
                WarmthSlider(value: $warmth) { store.setWarmth(device, Int($0)) }
            }
            if device.hasColour {
                HStack(spacing: 0) {
                    ForEach(Self.swatches, id: \.1) { s in
                        let selected = light?.mode == "colour" && light?.hue == s.1
                        Button { store.setColour(device, hue: s.1) } label: {
                            Circle().fill(Color(hue: Double(s.1) / 360, saturation: 0.8, brightness: 1))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 0.5))
                        }
                        .buttonStyle(Pressable())
                        .help(s.0)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(14)
        .card(16)
        .onAppear(perform: sync)
        .onChange(of: light) { sync() }
    }

    private func sync() {
        if let b = light?.brightness { brightness = Double(b) }
        if let w = light?.warmth { warmth = Double(w) }
    }
}

/// A chunky slider with an icon inside the track; commits when you let go.
struct TrackSlider: View {
    @Binding var value: Double
    let icon: String
    let fill: Color
    let commit: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(fill).frame(width: max(28, g.size.width * value / 100))
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(value > 12 ? Color.white : Color.secondary).padding(.leading, 9)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value = min(100, max(1, $0.location.x / g.size.width * 100)) }
                .onEnded { _ in commit(value) })
        }
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityLabel("Brightness")
        .accessibilityValue("\(Int(value)) percent")
        .accessibilityAdjustableAction { dir in
            value = min(100, max(1, value + (dir == .increment ? 10 : -10)))
            commit(value)
        }
    }
}

/// Cool-to-warm white slider.
struct WarmthSlider: View {
    @Binding var value: Double
    let commit: (Double) -> Void
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                let knob: CGFloat = 18
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [Color(red: 0.78, green: 0.88, blue: 1), .white, Color(red: 1, green: 0.76, blue: 0.42)],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    Circle().fill(.white).frame(width: knob, height: knob)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        .offset(x: (g.size.width - knob) * value / 100)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value = min(100, max(0, ($0.location.x - knob / 2) / (g.size.width - knob) * 100)) }
                    .onEnded { _ in commit(value) })
            }
            .frame(height: 20)
            HStack { Text("Cool"); Spacer(); Text("Warm") }.font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("White tone")
        .accessibilityValue(value < 34 ? "cool" : value > 66 ? "warm" : "neutral")
    }
}
