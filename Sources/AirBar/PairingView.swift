import AppKit
import CoreLocation
import CoreWLAN
import SwiftUI
import TuyaKit

// MARK: - Wi-Fi: current network, and devices waiting in hotspot mode

@MainActor @Observable
final class WiFiHelper: NSObject, CLLocationManagerDelegate {
    var ssid: String?
    var is5GHz = false
    var hotspots: [(ssid: String, rssi: Int)] = []
    var locationDenied = false
    private let location = CLLocationManager()

    override init() {
        super.init()
        location.delegate = self
    }

    /// macOS treats Wi-Fi names as location data, so reading them needs Location permission.
    func start() {
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .denied, .restricted: locationDenied = true
        default: break
        }
        refresh()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.locationDenied = [.denied, .restricted].contains(manager.authorizationStatus)
            self.refresh()
        }
    }

    func refresh() {
        let iface = CWWiFiClient.shared().interface()
        ssid = iface?.ssid()
        is5GHz = iface?.wlanChannel()?.channelBand == .band5GHz
        Task.detached(priority: .utility) {
            let nets = (try? iface?.scanForNetworks(withName: nil)) ?? []
            let found = nets.compactMap { n -> (String, Int)? in
                guard let s = n.ssid else { return nil }
                let l = s.lowercased()
                return l.hasPrefix("smartlife") || l.hasPrefix("tuya") || l.hasPrefix("sl-") || l.contains("homemate") ? (s, n.rssiValue) : nil
            }
            await MainActor.run { self.hotspots = found.sorted { $0.1 > $1.1 } }
        }
    }
}

// MARK: - Radar

struct RadarBlip: Identifiable, Hashable {
    enum Kind { case linked, onWiFi, hotspot, joined }
    var id: String
    var label: String
    var kind: Kind
    var strength: Double

    var color: Color {
        switch kind {
        case .linked, .joined: return .green
        case .onWiFi: return Theme.warm
        case .hotspot: return Theme.accent
        }
    }
}

struct RadarView: View {
    var blips: [RadarBlip]
    var scanning: Bool
    var size: CGFloat = 200

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !scanning)) { tl in
            let sweep = Angle.degrees((tl.date.timeIntervalSinceReferenceDate * 90).truncatingRemainder(dividingBy: 360))
            ZStack {
                ForEach(1..<4) { i in
                    Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        .frame(width: size * CGFloat(i) / 3, height: size * CGFloat(i) / 3)
                }
                if scanning {
                    Circle()
                        .fill(AngularGradient(gradient: Gradient(stops: [
                            .init(color: .clear, location: 0), .init(color: .clear, location: 0.86),
                            .init(color: Theme.accent.opacity(0.25), location: 1)]), center: .center))
                        .rotationEffect(sweep)
                }
                Image(systemName: "laptopcomputer").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(blips) { b in
                    let a = angle(b.id), r = (size / 2 - 14) * (1 - 0.7 * b.strength) + 8
                    VStack(spacing: 3) {
                        Circle().fill(b.color).frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                        Text(b.label).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(.background.opacity(0.85)))
                    }
                    .offset(x: cos(a) * r, y: sin(a) * r)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: blips)
        }
        .accessibilityElement()
        .accessibilityLabel("\(blips.count) devices nearby")
    }

    /// A stable angle per device so blips don't jump between scans.
    private func angle(_ id: String) -> Double {
        let h = id.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
        return Double(h % 360) * .pi / 180
    }
}

// MARK: - Wizard

@MainActor @Observable
final class PairModel {
    enum Phase { case prepare, wifi, connecting, done }
    struct Step: Identifiable { let id: PairingStep; let title: String; var state: State = .pending
        enum State { case pending, active, done, failed }
    }

    var phase: Phase = .prepare
    var ssid = ""
    var password = ""
    var steps = PairModel.freshSteps()
    var elapsed = 0
    let timeout = 120
    var error: String?
    var added: [TuyaDevice] = []
    var lan: [DiscoveredDevice] = []
    var joined: [String: String] = [:]
    var scanning = false
    let wifi = WiFiHelper()
    private var scanTask: Task<Void, Never>?
    private var pairTask: Task<Void, Never>?

    static func freshSteps() -> [Step] {
        [Step(id: .token, title: "Getting a pairing code from Tuya"), Step(id: .broadcast, title: "Sending your Wi-Fi details"),
         Step(id: .joined, title: "Device joining your network"), Step(id: .key, title: "Saving its local key")]
    }

    func blips(linked: Set<String>) -> [RadarBlip] {
        lan.map { RadarBlip(id: $0.id, label: linked.contains($0.id) ? "Linked" : "On Wi-Fi",
                            kind: linked.contains($0.id) ? .linked : .onWiFi, strength: 0.55) }
            + wifi.hotspots.map { RadarBlip(id: $0.ssid, label: $0.ssid, kind: .hotspot, strength: min(1, max(0, Double($0.rssi + 90) / 50))) }
            + joined.map { RadarBlip(id: "j-" + $0.key, label: $0.value.isEmpty ? "New device" : $0.value, kind: .joined, strength: 0.9) }
    }

    func startScanning() {
        wifi.start()
        scanTask?.cancel()
        scanTask = Task {
            while !Task.isCancelled {
                scanning = true
                lan = await TuyaDiscovery.scan(seconds: 4)
                wifi.refresh()
                if ssid.isEmpty, let s = wifi.ssid { ssid = s }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        pairTask?.cancel()
        scanning = false
    }

    func reset() {
        phase = .prepare; steps = Self.freshSteps(); error = nil; added = []; joined = [:]; elapsed = 0
    }

    func connect(cloud: TuyaCloud, onDone: @escaping () -> Void) {
        phase = .connecting
        steps = Self.freshSteps()
        error = nil
        let (ssid, password, timeout) = (ssid, password, timeout)
        pairTask = Task {
            do {
                added = try await Pairing.run(cloud: cloud, ssid: ssid, password: password, timeout: timeout) { event in
                    Task { @MainActor in self.handle(event) }
                }
            } catch {
                self.error = error.localizedDescription
            }
            self.password = ""
            phase = .done
            onDone()
        }
    }

    private func handle(_ event: PairingEvent) {
        switch event {
        case .progress(let e, _): elapsed = e
        case .joined(let id, let name): joined[id] = name
        case .step(let step, let state, let message):
            if let message { error = message }
            guard let i = steps.firstIndex(where: { $0.id == step }) else { return }
            steps[i].state = state == .active ? .active : state == .done ? .done : .failed
            if state != .failed { for j in 0..<i where steps[j].state != .failed { steps[j].state = .done } }
        }
    }
}

struct PairingView: View {
    @Environment(Store.self) var store
    @State private var model = PairModel()
    var close: () -> Void

    private var stepIndex: Int {
        switch model.phase { case .prepare: 0; case .wifi: 1; case .connecting: 2; case .done: 3 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { model.stop(); close() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12, weight: .medium))
                Spacer()
                StepDots(titles: ["Prepare", "Wi-Fi", "Connect", "Done"], current: stepIndex)
            }
            HStack(alignment: .top, spacing: 18) {
                RadarView(blips: model.blips(linked: Set(store.devices.map(\.id))), scanning: model.phase != .done)
                VStack(alignment: .leading, spacing: 10) {
                    switch model.phase {
                    case .prepare: prepare
                    case .wifi: wifi
                    case .connecting: connecting
                    case .done: done
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .card(16)
            HStack(spacing: 14) {
                legend(.green, "Linked to AirBar")
                legend(Theme.warm, "On Wi-Fi, not linked")
                legend(Theme.accent, "Waiting in hotspot mode")
                Spacer()
                if model.wifi.locationDenied {
                    Button("Allow Wi-Fi scanning") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .onAppear { if !store.demo { model.startScanning() } }
        .onDisappear { model.stop() }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 7, height: 7); Text(t) }
    }

    private var prepare: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Put the device in pairing mode").font(.system(size: 14, weight: .semibold))
            NumberedStep(n: 1, text: "Turn it off and on 3 times, about a second each.")
            NumberedStep(n: 2, text: "Wait until its light blinks fast, about twice a second.")
            NumberedStep(n: 3, text: "Keep it close to your router.")
            Text("Slow blinking means hotspot mode. Do the off/on cycle once more to switch to fast blinking.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("It's blinking fast") { model.phase = .wifi }.buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
        }
    }

    private var wifi: some View {
        @Bindable var m = model
        return VStack(alignment: .leading, spacing: 10) {
            Text("Your Wi-Fi").font(.system(size: 14, weight: .semibold))
            Text("The device joins this network. It must be 2.4 GHz.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Field(placeholder: "Network name", text: $m.ssid, icon: "wifi")
            Field(placeholder: "Wi-Fi password", text: $m.password, secure: true, icon: "lock")
            if model.wifi.is5GHz {
                Label("Your Mac is on 5 GHz. Most routers still pass pairing packets on, but if pairing fails, join the 2.4 GHz network.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Back") { model.phase = .prepare }.buttonStyle(SecondaryButtonStyle())
                Button("Connect") { model.connect(cloud: store.tuyaCloud) { store.reloadDevices() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.ssid.isEmpty || model.password.count < 8)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var connecting: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connecting…").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(max(0, model.timeout - model.elapsed)) s").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: Double(model.elapsed), total: Double(model.timeout)).tint(Theme.accent)
            ForEach(model.steps) { s in
                HStack(spacing: 8) {
                    Group {
                        switch s.state {
                        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                        case .active: ProgressView().controlSize(.mini)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                    .frame(width: 16)
                    Text(s.title).font(.system(size: 12)).foregroundStyle(s.state == .pending ? .secondary : .primary)
                }
            }
            StatusLine(error: model.error)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.added.isEmpty {
                Label("Nothing was added", systemImage: "xmark.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.red)
                StatusLine(error: model.error ?? "The device didn't join.")
                Button("Try again") { model.reset() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Label("Connected", systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
                ForEach(model.added) { d in
                    HStack(spacing: 8) { BulbGlyph(on: true, color: Theme.warm, size: 22); Text(d.name).font(.system(size: 12.5, weight: .medium)) }
                }
                Text("It's in your menu bar now, controlled directly over your Wi-Fi.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Add another") { model.reset() }.buttonStyle(SecondaryButtonStyle())
                    Button("Done") { model.stop(); close() }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }
}

struct StepDots: View {
    let titles: [String]
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(titles.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Circle().fill(i <= current ? Theme.accent : Color.primary.opacity(0.15)).frame(width: 7, height: 7)
                    Text(titles[i]).font(.system(size: 10.5, weight: i == current ? .semibold : .regular))
                        .foregroundStyle(i == current ? .primary : .secondary)
                }
                if i < titles.count - 1 { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 10, height: 1) }
            }
        }
    }
}

struct NumberedStep: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Theme.accent))
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
