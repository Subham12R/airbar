import SwiftUI

enum Theme {
    static let accent = Color(red: 0.2, green: 0.55, blue: 1)
    static let warm = Color(red: 1, green: 0.62, blue: 0.2)

    /// One flat colour per mode.
    static func mode(_ mode: String?) -> Color {
        switch mode {
        case "HEATING": return Color(red: 0.95, green: 0.42, blue: 0.25)
        case "DRY", "DRY_COOL": return Color(red: 0.16, green: 0.68, blue: 0.7)
        case "FAN": return Color(red: 0.3, green: 0.7, blue: 0.45)
        case "AUTO": return Color(red: 0.55, green: 0.45, blue: 0.95)
        default: return Color(red: 0.2, green: 0.55, blue: 1)
        }
    }

    static let modeInfo: [String: (label: String, icon: String)] = [
        "COOLING": ("Cool", "snowflake"), "HEATING": ("Heat", "flame.fill"), "DRY": ("Dry", "drop.fill"),
        "DRY_COOL": ("Dry Cool", "drop.halffull"), "FAN": ("Fan", "fanblades.fill"),
        "AUTO": ("Auto", "arrow.triangle.2.circlepath"),
    ]
    static let swingLabel = ["OFF": "Fixed", "VERTICAL": "Up–Down", "HORIZONTAL": "Side", "BOTH": "All", "AUTO": "Auto"]

    static func fanLabel(_ f: String) -> String { f == "AUTO" ? "Auto" : (f.hasPrefix("LV") ? String(f.dropFirst(2)) : f.capitalized) }
}

// MARK: - Surfaces: flat translucent fills with a hairline edge

private struct Surface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color.primary.opacity(scheme == .dark ? 0.07 : 0.045)))
            .background(shape.fill((tint ?? .clear).opacity(0.22)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

extension View {
    func card(_ radius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(Surface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint))
    }
    func circleSurface(tint: Color? = nil) -> some View { modifier(Surface(shape: Circle(), tint: tint)) }
    func capsuleSurface(tint: Color? = nil) -> some View { modifier(Surface(shape: Capsule(), tint: tint)) }
}

// MARK: - Buttons

struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(enabled ? Theme.accent : Color.gray.opacity(0.45)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct IconButton: View {
    let icon: String
    var help: String = ""
    var size: CGFloat = 30
    var spinning = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .circleSurface()
        .help(help)
    }
}

// MARK: - Text field with icon and show/hide

struct Field: View {
    var placeholder: String
    @Binding var text: String
    var secure = false
    var icon: String? = nil
    @State private var reveal = false
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16) }
            Group {
                if secure && !reveal { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            if secure {
                if !text.isEmpty {
                    Text("\(text.count)").font(.system(size: 10.5)).foregroundStyle(.tertiary).help("Characters typed")
                }
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help(reveal ? "Hide" : "Show")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .card(10)
    }
}

struct StatusLine: View {
    var error: String?
    var success: String?
    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let success {
            Label(success, systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
