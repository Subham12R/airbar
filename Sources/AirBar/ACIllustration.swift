import AirCloudKit
import SwiftUI

/// A wall-mounted split unit drawn to scale: chassis, underside vent with a louver that opens and
/// sweeps, a small LED readout, and airflow in the mode colour that speeds up with the fan.
struct ACIllustration: View {
    let unit: ACUnit
    @Environment(\.colorScheme) private var scheme

    private var color: Color { Theme.mode(unit.mode) }
    private var sweepsVertically: Bool { ["VERTICAL", "BOTH", "AUTO"].contains(unit.fanSwing) }
    private var sweepsSideways: Bool { ["HORIZONTAL", "BOTH"].contains(unit.fanSwing) }
    private var flowSpeed: Double {
        ["LV1": 0.5, "LV2": 0.75, "LV3": 1.0, "LV4": 1.3, "LV5": 1.6][unit.fanSpeed] ?? 0.9
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !unit.isOn)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            VStack(spacing: 0) {
                chassis(t: t)
                Airflow(color: color, time: t * flowSpeed, sway: sweepsSideways ? sin(t * 0.9) : 0)
                    .frame(height: 40)
                    .padding(.horizontal, 12)
                    .opacity(unit.isOn ? 1 : 0)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            }
        }
        .animation(.smooth(duration: 0.5), value: unit.isOn)
        .animation(.smooth(duration: 0.5), value: unit.mode)
        .accessibilityElement()
        .accessibilityLabel("\(unit.name), \(unit.isOn ? "on" : "off")")
    }

    private func chassis(t: Double) -> some View {
        let shell = Color(white: scheme == .dark ? 0.9 : 0.975)
        let underside = Color(white: scheme == .dark ? 0.8 : 0.9)
        let louver: Double = !unit.isOn ? 0 : (sweepsVertically ? 32 + 16 * sin(t * 1.1) : 36)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack(alignment: .bottom) {
            shape.fill(shell)
            Rectangle().fill(underside).frame(height: 15)
            Capsule().fill(Color(white: 0.22)).frame(height: 5)
                .padding(.horizontal, 18).padding(.bottom, 5)
                .opacity(unit.isOn ? 1 : 0.25)
            Capsule().fill(Color(white: scheme == .dark ? 0.86 : 0.95))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                .frame(height: 6)
                .padding(.horizontal, 16)
                .rotation3DEffect(.degrees(louver), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.45)
                .padding(.bottom, 4.5)
            HStack(spacing: 8) {
                Spacer()
                Circle().fill(unit.isOn ? color : Color(white: 0.75)).frame(width: 4, height: 4)
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(white: 0.14))
                    Text(readout).font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(color)
                        .contentTransition(.numericText())
                }
                .frame(width: 38, height: 16)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.bottom, 14)
        }
        .frame(height: 56)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }

    private var readout: String {
        guard unit.isOn else { return "" }
        guard unit.rules?.temperature != false, let t = unit.iduTemperature else { return "FAN" }
        return t.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f°", t) : String(format: "%.1f°", t)
    }
}

/// Dashed wavy streams leaving the vent.
struct Airflow: View {
    var color: Color
    var time: Double
    var sway: Double

    var body: some View {
        Canvas { ctx, size in
            let streams = 9
            for i in 0..<streams {
                let f = Double(i) / Double(streams - 1)
                let x0 = size.width * (0.12 + 0.76 * f)
                var path = Path()
                for y in stride(from: 0.0, through: size.height, by: 2) {
                    let k = y / size.height
                    let x = x0 + (x0 - size.width / 2) * k * 0.35 + sin(time * 2.2 + k * 5 + Double(i)) * 4 * k + sway * 14 * k
                    if y == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path,
                           with: .linearGradient(Gradient(colors: [color.opacity(0.45), color.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [9, 9], dashPhase: -(time * 34 + Double(i) * 5)))
            }
        }
    }
}
