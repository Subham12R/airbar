import AirCloudKit
import Foundation
import Observation
import ServiceManagement

/// App state. Taps change local (optimistic) state immediately; a per-unit queue sends the
/// whole desired state to airCloud one command at a time, merging bursts of taps.
@MainActor @Observable
final class Store {
    var units: [ACUnit] = []
    var signedIn = false
    var account: String?
    var loaded = false
    var loading = false
    var banner: String?
    var busy: Set<String> = []
    var config: AirBarConfig
    let demo: Bool

    private let client: AirCloudClient
    private var dirty: Set<String> = []
    private var workers: [String: Task<Void, Never>] = [:]
    private var timer: Timer?

    init(demo: Bool = CommandLine.arguments.contains("--demo")) {
        self.demo = demo
        let cfg = AirBarConfig.load()
        config = cfg
        client = AirCloudClient(config: cfg)
        if demo {
            units = [Self.demoUnit]
            signedIn = true
            account = "demo@example.com"
            loaded = true
        }
    }

    var running: ACUnit? { units.first(where: \.isOn) }

    func start() {
        guard timer == nil, !demo else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: max(15, config.refreshIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        if demo || loading || !workers.isEmpty { return }  // don't overwrite changes still being sent
        loading = true
        defer { loading = false; loaded = true }
        signedIn = await client.isSignedIn
        account = await client.accountLabel
        guard signedIn else { units = []; return }
        do {
            units = try await client.units()
            banner = nil
        } catch {
            banner = error.localizedDescription
        }
    }

    // MARK: Account

    func signIn(_ method: SignInMethod, password: String) async throws {
        try await client.signIn(method, password: password)
        await refresh()
    }

    func signOut() async {
        await client.signOut()
        units = []
        signedIn = false
        account = nil
    }

    // MARK: Controls

    func togglePower(_ u: ACUnit) { mutate(u.id) { $0.power = $0.isOn ? "OFF" : "ON" } }

    func nudge(_ u: ACUnit, steps: Double) {
        guard let r = u.rules, r.temperature else { return }
        let lo = r.minTemperature ?? 16, hi = r.maxTemperature ?? 32
        mutate(u.id) { a in
            a.iduTemperature = min(hi, max(lo, (a.iduTemperature ?? lo) + steps * r.temperatureStep))
            a.power = "ON"
        }
    }

    func setMode(_ u: ACUnit, _ mode: String) {
        mutate(u.id) { a in
            a.mode = mode
            a.power = "ON"
            if let r = a.capabilities?.byMode[mode] {
                if !r.fans.isEmpty && !r.fans.contains(a.fanSpeed) { a.fanSpeed = r.defaultFan }
                if r.temperature, let lo = r.minTemperature, let hi = r.maxTemperature {
                    a.iduTemperature = min(hi, max(lo, a.iduTemperature ?? lo))
                }
            }
        }
    }

    func setFan(_ u: ACUnit, _ fan: String) { mutate(u.id) { $0.fanSpeed = fan } }
    func setSwing(_ u: ACUnit, _ swing: String) { mutate(u.id) { $0.fanSwing = swing } }

    private func mutate(_ id: String, _ change: (inout ACUnit) -> Void) {
        guard let i = units.firstIndex(where: { $0.id == id }) else { return }
        change(&units[i])
        enqueue(id)
    }

    private func enqueue(_ id: String) {
        dirty.insert(id)
        guard !demo, workers[id] == nil else { return }
        workers[id] = Task {
            try? await Task.sleep(nanoseconds: UInt64(config.coalesceMilliseconds) * 1_000_000)
            while dirty.contains(id) {
                dirty.remove(id)
                guard let unit = units.first(where: { $0.id == id }) else { break }
                busy.insert(id)
                do {
                    try await client.send(DesiredState(of: unit), to: unit)
                } catch {
                    banner = error.localizedDescription
                }
                busy.remove(id)
            }
            workers[id] = nil
            await refresh()
        }
    }

    // MARK: Settings

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                banner = "Couldn't change the login item: \(error.localizedDescription)"
            }
        }
    }

    func saveConfig() {
        do { try config.save() } catch { banner = "Couldn't save settings: \(error.localizedDescription)" }
    }

    // MARK: Demo data (screenshots, previews)

    static let demoUnit = ACUnit(
        id: "1", name: "Living Room", power: "ON", mode: "COOLING", iduTemperature: 24.5, roomTemperature: 27.5,
        fanSpeed: "LV2", fanSwing: "VERTICAL", capabilities: Capabilities(
            modes: ["COOLING", "DRY", "FAN", "AUTO"], swings: ["OFF", "VERTICAL"], byMode: [
                "COOLING": ModeRules(temperature: true, minTemperature: 16, maxTemperature: 32, temperatureStep: 0.5,
                                     fans: ["AUTO", "LV1", "LV2", "LV3", "LV4", "LV5"], defaultFan: "AUTO"),
                "DRY": ModeRules(temperature: true, minTemperature: 16, maxTemperature: 32, temperatureStep: 0.5,
                                 fans: ["AUTO", "LV1", "LV2"], defaultFan: "AUTO"),
                "FAN": ModeRules(temperature: false, minTemperature: nil, maxTemperature: nil, temperatureStep: 1,
                                 fans: ["LV1", "LV2", "LV3", "LV4", "LV5"], defaultFan: "LV2"),
                "AUTO": ModeRules(temperature: true, minTemperature: 24, maxTemperature: 24, temperatureStep: 1,
                                  fans: ["AUTO", "LV1", "LV5"], defaultFan: "AUTO"),
            ]))
}
