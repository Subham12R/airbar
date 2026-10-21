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
                    Text("Connecting to airCloud…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).card(14)
            } else if !store.signedIn {
                Message(icon: "person.crop.circle.badge.plus", title: "Sign in to airCloud",
                        text: "Use the same phone number or email as the airCloud Go app.",
                        button: "Sign in") { openSettings() }
            } else if store.units.isEmpty {
                Message(icon: "air.conditioner.horizontal", title: "No air conditioners yet",
                        text: "Your airCloud home is empty. Add the unit in the airCloud Go app and it appears here.",
                        button: nil) {}
            } else {
                ForEach(store.units) { ACCard(unit: $0) }
            }
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "air.conditioner.horizontal.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent))
            VStack(alignment: .leading, spacing: 1) {
                Text("AirBar").font(.system(size: 15, weight: .bold))
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(icon: "arrow.clockwise", help: "Refresh", spinning: store.loading) { Task { await store.refresh() } }
        }
    }

    private var summary: String {
        if !store.signedIn { return "Not signed in" }
        let on = store.units.filter(\.isOn)
        if on.isEmpty { return store.units.isEmpty ? "No units" : "All off" }
        return on.map { u in u.iduTemperature.map { "\(u.name) \(String(format: "%g", $0))°" } ?? u.name }.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            if let account = store.account {
                Text(account).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            IconButton(icon: "gearshape", help: "Settings", size: 28) { openSettings() }
            IconButton(icon: "xmark", help: "Quit AirBar", size: 28) { NSApp.terminate(nil) }
        }
    }

    private func openSettings() {
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
