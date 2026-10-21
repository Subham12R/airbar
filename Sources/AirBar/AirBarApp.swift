import AirCloudKit
import AppKit
import ServiceManagement
import SwiftUI

@main
struct AirBarApp: App {
    @State private var store = Store()

    init() {
        // `open -a AirBar --args --enable-login-item` (or --disable-login-item), for install scripts.
        // macOS only lets an app register its own login item, so this has to run inside AirBar.
        let args = CommandLine.arguments
        if args.contains("--enable-login-item") { try? SMAppService.mainApp.register() }
        if args.contains("--disable-login-item") { try? SMAppService.mainApp.unregister() }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel().environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("AirBar Settings", id: "settings") {
            SettingsView().environment(store)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuBarLabel: View {
    let store: Store
    var body: some View {
        HStack(spacing: 3) {
            // Always the house: filled while anything (AC or a light) is on.
            Image(systemName: store.running != nil || store.switchesOn > 0 ? "house.fill" : "house")
            if store.config.showTemperatureInMenuBar, let u = store.running, u.rules?.temperature != false, let t = u.iduTemperature {
                Text(String(format: "%g°", t))
            }
        }
        .onAppear {
            store.start()
            Preview.runIfRequested()
        }
    }
}

/// `AirBar --demo --preview out.png [--settings TAB] [--dark]` shows a screen with demo data in a
/// normal window and screenshots it. Used for the README images; harmless otherwise.
@MainActor
enum Preview {
    static var window: NSWindow?

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview"), i + 1 < args.count else { return }
        let dark = args.contains("--dark")
        let store = Store(demo: true)
        let root: AnyView
        if let t = args.firstIndex(of: "--settings"), t + 1 < args.count {
            if args[t + 1] != "account-signed-in" { store.signedIn = false }
            if args[t + 1] == "pairing" {
                root = AnyView(PairingView {}.environment(store).padding(22).frame(width: 560))
                return show(root, dark: dark, out: args[i + 1])
            }
            let tab = SettingsView.Tab(rawValue: args[t + 1].capitalized) ?? .account
            root = AnyView(SettingsView(tab: tab).environment(store))
        } else {
            root = AnyView(Panel().environment(store))
        }
        show(root, dark: dark, out: args[i + 1])
    }

    static func show(_ root: AnyView, dark: Bool, out: String) {
        let host = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.hasShadow = true
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.isOpaque = false
        w.backgroundColor = .clear
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        w.contentView = effect
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        w.setContentSize(host.fittingSize)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {  // panel has measured itself: fit the window
            w.setContentSize(host.fittingSize)
            w.center()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(w.windowNumber), out]
            try? p.run()
            p.waitUntilExit()
            exit(0)
        }
    }
}
