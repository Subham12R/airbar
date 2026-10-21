import AirCloudKit
import SwiftUI

struct ACCard: View {
    @Environment(Store.self) var store
    let unit: ACUnit

    private var color: Color { Theme.mode(unit.mode) }
    private var rules: ModeRules? { unit.rules }
    private var hasTemperature: Bool { rules?.temperature ?? (unit.mode != "FAN") }
    private var temp: Double { unit.iduTemperature ?? 24 }
    private var lo: Double { rules?.minTemperature ?? 16 }
    private var hi: Double { rules?.maxTemperature ?? 32 }
    private var modes: [String] { unit.capabilities?.modes ?? ["COOLING", "HEATING", "DRY", "FAN", "AUTO"] }
    private var fans: [String] { rules?.fans ?? ["AUTO", "LV1", "LV2", "LV3", "LV4", "LV5"] }
    private var swings: [String] { unit.capabilities?.swings ?? ["OFF", "VERTICAL"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(unit.name).font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 6) {
                        Chip(icon: "thermometer.medium",
                             text: unit.roomTemperature.map { String(format: "%.1f° inside", $0) } ?? "Room —")
                        if store.busy.contains(unit.id) {
                            Chip(icon: "arrow.triangle.2.circlepath", text: "Updating…", tint: color)
                        } else {
                            Chip(icon: "circle.fill", text: !unit.online ? "Offline" : (unit.isOn ? "Running" : "Standby"),
                                 tint: !unit.online ? .red : (unit.isOn ? .green : .secondary))
                        }
                    }
                }
                Spacer()
                PowerButton(on: unit.isOn, color: color) { store.togglePower(unit) }
            }

            ACIllustration(unit: unit)
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                IconButton(icon: "minus", help: "Cooler", size: 38) { store.nudge(unit, steps: -1) }
                    .disabled(!hasTemperature || temp <= lo).opacity(!hasTemperature || temp <= lo ? 0.35 : 1)
                Spacer()
                VStack(spacing: 6) {
                    if hasTemperature {
                        TemperatureText(value: temp).opacity(unit.isOn ? 1 : 0.4)
                        RangeBar(value: temp, lo: lo, hi: hi, color: color, active: unit.isOn).frame(width: 160, height: 4)
                    } else {
                        Label("Fan only", systemImage: "fanblades.fill").font(.system(size: 20, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary).frame(height: 54)
                    }
                }
                Spacer()
                IconButton(icon: "plus", help: "Warmer", size: 38) { store.nudge(unit, steps: 1) }
                    .disabled(!hasTemperature || temp >= hi).opacity(!hasTemperature || temp >= hi ? 0.35 : 1)
            }

            HStack(spacing: 6) {
                ForEach(modes, id: \.self) { m in
                    let info = Theme.modeInfo[m] ?? (m.capitalized, "circle")
                    ModePill(icon: info.icon, label: info.label, selected: unit.mode == m && unit.isOn, color: Theme.mode(m)) {
                        store.setMode(unit, m)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                OptionRow(icon: "wind", title: "Fan", options: fans.map { ($0, Theme.fanLabel($0)) },
                          selected: unit.fanSpeed, tint: color) { store.setFan(unit, $0) }
                OptionRow(icon: "arrow.up.and.down", title: "Swing",
                          options: swings.map { ($0, Theme.swingLabel[$0] ?? $0.capitalized) },
                          selected: unit.fanSwing, tint: color) { store.setSwing(unit, $0) }
            }
        }
        .padding(16)
        .card(16)
    }
}

struct Chip: View {
    let icon: String
    let text: String
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: icon == "circle.fill" ? 5.5 : 10, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

struct TemperatureText: View {
    let value: Double
    var body: some View {
        let whole = Int(value.rounded(.down))
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(whole)").font(.system(size: 48, weight: .light, design: .rounded)).contentTransition(.numericText(value: value))
            Text(value - Double(whole) >= 0.25 ? ".5" : "").font(.system(size: 22, weight: .light, design: .rounded))
            Text("°").font(.system(size: 30, weight: .ultraLight, design: .rounded)).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .animation(.snappy, value: value)
        .frame(height: 54)
        .accessibilityLabel(String(format: "Set to %g degrees", value))
    }
}

struct RangeBar: View {
    let value: Double
    let lo: Double
    let hi: Double
    let color: Color
    let active: Bool
    var body: some View {
        GeometryReader { g in
            let f = hi > lo ? (value - lo) / (hi - lo) : 1
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(active ? color : .gray).frame(width: max(4, g.size.width * f))
            }
            .animation(.snappy, value: value)
        }
    }
}

struct PowerButton: View {
    let on: Bool
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(on ? .white : .secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(color).opacity(on ? 1 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .circleSurface()
        .help(on ? "Turn off" : "Turn on")
        .accessibilityLabel(on ? "Turn off" : "Turn on")
        .animation(.smooth, value: on)
    }
}

struct ModePill: View {
    let icon: String
    let label: String
    let selected: Bool
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).frame(height: 15)
                    .symbolEffect(.bounce, value: selected)
                Text(label).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(selected ? .white : .primary.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color).opacity(selected ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .card(10)
        .animation(.smooth(duration: 0.25), value: selected)
    }
}

struct OptionRow: View {
    let icon: String
    let title: String
    let options: [(String, String)]
    let selected: String?
    let tint: Color
    let pick: (String) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(options, id: \.0) { opt in
                    let on = selected == opt.0
                    Button { pick(opt.0) } label: {
                        Text(opt.1)
                            .font(.system(size: 11, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? .white : .primary.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background { if on { Capsule().fill(tint).matchedGeometryEffect(id: "sel", in: ns) } }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(Pressable())
                }
            }
            .padding(2)
            .capsuleSurface()
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        }
    }
}
