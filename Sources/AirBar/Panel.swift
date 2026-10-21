import AirCloudKit
import AppKit
import SwiftUI

/// The popover shown from the menu bar.
struct Panel: View {
    @Environment(Store.self) var store
    @Environment(\.openWindow) private var openWindow
    @State private var height: CGFloat = 420
    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 40 }

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 380, height: min(height, maxHeight))
        .onAppear { store.start() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let banner = store.banner { Banner(text: banner) { store.banner = nil } }
            if !store.loaded {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).card(14)
            } else {
                if store.signedIn {
                    if store.units.isEmpty {
                        Message(icon: "air.conditioner.horizontal", title: "No air conditioners yet",
                                text: "Your airCloud home is empty. Add the unit in the airCloud Go app and it appears here.",
                                button: nil) {}
                    } else {
                        ForEach(store.units) { ACCard(unit: $0) }
                    }
                } else if store.devices.isEmpty {
                    Welcome(signIn: { openSettings(.account) }, addDevices: { openSettings(.devices) })
                } else {
                    Button { openSettings(.account) } label: {
                        Label("Connect your Hitachi AC", systemImage: "air.conditioner.horizontal")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable())
                    .card(12)
                }
                if !store.devices.isEmpty { LightsSection() }
            }
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("AirBar").font(.system(size: 15, weight: .bold))
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: store.loading) { Task { await store.refresh() } }
        }
    }

    private var summary: String {
        var parts = store.units.filter(\.isOn).map { u in
            u.iduTemperature.map { "\(u.name) \(String(format: "%g", $0))°" } ?? u.name
        }
        if !store.devices.isEmpty { parts.append(store.switchesOn == 0 ? "lights off" : "\(store.switchesOn) on") }
        if parts.isEmpty { return store.signedIn ? (store.units.isEmpty ? "No units" : "All off") : "Not set up" }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            if let account = store.account {
                Text(account).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if store.switchesOn > 0 {
                IconButton(icon: "lightbulb.slash", help: "Turn off all lights and switches", size: 28) { store.everythingOff() }
            }
            IconButton(icon: "gearshape", help: "Settings", size: 28) { openSettings() }
            IconButton(icon: "xmark", help: "Quit AirBar", size: 28) { NSApp.terminate(nil) }
        }
    }

    private func openSettings(_ tab: SettingsView.Tab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct Banner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 11)).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .card(12, tint: .orange)
    }
}

struct Message: View {
    let icon: String
    let title: String
    let text: String
    let button: String?
    let action: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let button { Button(button, action: action).buttonStyle(PrimaryButtonStyle()) }
        }
        .padding(18).frame(maxWidth: .infinity)
        .card(16)
    }
}

struct Welcome: View {
    let signIn: () -> Void
    let addDevices: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "air.conditioner.horizontal").font(.system(size: 24))
                Image(systemName: "lightbulb").font(.system(size: 24))
            }
            .foregroundStyle(.secondary)
            Text("Set up AirBar").font(.system(size: 14, weight: .semibold))
            Text("Connect your Hitachi air conditioner, your HomeMate (Tuya) lights and switches, or both.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Sign in to airCloud", action: signIn).buttonStyle(PrimaryButtonStyle())
                Button("Add lights & switches", action: addDevices).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(18).frame(maxWidth: .infinity)
        .card(16)
    }
}
