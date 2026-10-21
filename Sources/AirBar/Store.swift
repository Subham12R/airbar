import AirCloudKit
import Foundation
import Observation
import ServiceManagement
import TuyaKit

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

    // HomeMate / Tuya
    var devices: [TuyaDevice] = []
    var deviceStates: [String: DeviceState] = [:]
    var busyDevices: Set<String> = []
    var cloudConnected = false
    let tuyaCloud = TuyaCloud()

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
            // --demo-mode DRY / --demo-off / --demo-fan LV4 vary the demo unit for screenshots.
            var unit = Self.demoUnit
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--demo-mode"), i + 1 < args.count {
                unit.mode = args[i + 1].uppercased()
                if let r = unit.capabilities?.byMode[unit.mode] {
                    if !r.fans.contains(unit.fanSpeed) { unit.fanSpeed = r.defaultFan }
                    if r.temperature, let lo = r.minTemperature, let hi = r.maxTemperature {
                        unit.iduTemperature = min(hi, max(lo, unit.iduTemperature ?? lo))
                    }
                }
            }
            if let i = args.firstIndex(of: "--demo-fan"), i + 1 < args.count { unit.fanSpeed = args[i + 1].uppercased() }
            if args.contains("--demo-off") { unit.power = "OFF" }
            units = args.contains("--demo-no-ac") ? [] : [unit]
            signedIn = !args.contains("--demo-no-ac")
            account = "demo@example.com"
            if !args.contains("--demo-no-lights") {
                devices = Self.demoDevices
                deviceStates = Self.demoStates
                cloudConnected = true
            }
            loaded = true
        } else {
            devices = DeviceStore.load()
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
        async let lights: Void = refreshDevices()
        signedIn = await client.isSignedIn
        account = await client.accountLabel
        cloudConnected = await tuyaCloud.isConnected
        if signedIn {
            do {
                units = try await client.units()
                banner = nil
            } catch {
                banner = error.localizedDescription
            }
        } else {
            units = []
        }
        await lights
    }

    func refreshDevices() async {
        guard !demo else { return }
        devices = DeviceStore.load()
        let list = devices
        let states = await withTaskGroup(of: (String, DeviceState).self) { group in
            for d in list { group.addTask { (d.id, await TuyaControl.state(of: d)) } }
            var out: [String: DeviceState] = [:]
            for await (id, st) in group { out[id] = st }
            return out
        }
        for (id, st) in states where !busyDevices.contains(id) { deviceStates[id] = st }
    }

    // MARK: Lights and switches

    var switchesOn: Int {
        devices.reduce(0) { n, d in n + (deviceStates[d.id]?.toggles.values.filter { $0 }.count ?? 0) }
    }

    func toggle(_ d: TuyaDevice, dp: String) {
        let on = !(deviceStates[d.id]?.toggles[dp] ?? false)
        mutateDevice(d.id) { s in s.toggles[dp] = on; if d.powerDP == dp { s.light?.on = on } }
        perform(d) { try await TuyaControl.setToggle(d, dp: dp, on: on) }
    }

    func setBrightness(_ d: TuyaDevice, _ percent: Int) {
        mutateDevice(d.id) { s in s.light?.brightness = percent; s.light?.on = true; if let p = d.powerDP { s.toggles[p] = true } }
        perform(d) { try await TuyaControl.setBrightness(d, percent: percent) }
    }

    func setWarmth(_ d: TuyaDevice, _ percent: Int) {
        mutateDevice(d.id) { s in s.light?.warmth = percent; s.light?.mode = "white"; s.light?.on = true }
        perform(d) { try await TuyaControl.setWarmth(d, percent: percent) }
    }

    func setColour(_ d: TuyaDevice, hue: Int) {
        mutateDevice(d.id) { s in s.light?.hue = hue; s.light?.mode = "colour"; s.light?.on = true; if let p = d.powerDP { s.toggles[p] = true } }
        perform(d) { try await TuyaControl.setColour(d, hue: hue) }
    }

    func everythingOff() {
        for d in devices where deviceStates[d.id]?.toggles.values.contains(true) == true {
            mutateDevice(d.id) { s in for k in s.toggles.keys { s.toggles[k] = false }; s.light?.on = false }
            perform(d) { try await TuyaControl.setAll(d, on: false) }
        }
    }

    private func mutateDevice(_ id: String, _ change: (inout DeviceState) -> Void) {
        var s = deviceStates[id] ?? DeviceState(online: true)
        change(&s)
        deviceStates[id] = s
    }

    private func perform(_ d: TuyaDevice, _ op: @escaping @Sendable () async throws -> Void) {
        guard !demo else { return }
        busyDevices.insert(d.id)
        Task {
            do { try await op() } catch { banner = "\(d.name): \(error.localizedDescription)" }
            busyDevices.remove(d.id)
            if let fresh = DeviceStore.load().first(where: { $0.id == d.id }) {
                deviceStates[d.id] = await TuyaControl.state(of: fresh)
            }
        }
    }

    // MARK: Managing devices

    func reloadDevices() {
        devices = DeviceStore.load()
        Task { await refreshDevices() }
    }

    func rename(_ id: String, to name: String) {
        try? DeviceStore.update(id) { $0.name = name }
        reloadDevices()
    }

    func renameSwitch(_ id: String, dp: String, to name: String) {
        try? DeviceStore.update(id) { d in d.toggles = d.toggles.map { $0.dp == dp ? .init(dp: dp, name: name) : $0 } }
        reloadDevices()
    }

    func removeDevice(_ id: String) {
        try? DeviceStore.remove(id)
        deviceStates[id] = nil
        reloadDevices()
    }

    /// Validates the Tuya project, links the Smart Life user, and imports every device with its key.
    func connectCloud(accessId: String, secret: String, region: String) async throws -> Int {
        try await tuyaCloud.connect(accessId: accessId, accessSecret: secret, region: region, knownDeviceIds: devices.map(\.id))
        cloudConnected = true
        return try await importFromCloud()
    }

    func importFromCloud() async throws -> Int {
        let lan = await TuyaDiscovery.scan(seconds: 6)
        let found = try await tuyaCloud.importDevices(lan: lan)
        for (d, key) in found { try DeviceStore.upsert(d, key: key) }
        reloadDevices()
        return found.count
    }

    func disconnectCloud() async {
        await tuyaCloud.disconnect()
        cloudConnected = false
    }

    /// Adds a device by ID and local key; reads it once to work out what it is.
    func addManually(id: String, key: String, name: String, ip: String?) async throws {
        var address = ip?.trimmingCharacters(in: .whitespaces) ?? ""
        var version = "3.5"
        if let hit = await TuyaDiscovery.scan(seconds: 6).first(where: { $0.id == id }) {
            if address.isEmpty { address = hit.ip }
            version = hit.version
        }
        guard !address.isEmpty else { throw TuyaError.device("That device isn't broadcasting on your Wi-Fi. Check the ID, or enter its IP address.") }
        let dps = try await TuyaLocal.status(id: id, ip: address, version: TuyaVersion(string: version) ?? .v35, key: key)
        let record = DeviceRecords.fromStatus(id: id, name: name.isEmpty ? "Device" : name, ip: address, version: version, dps: dps)
        try DeviceStore.upsert(record, key: key)
        reloadDevices()
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

    static let demoDevices: [TuyaDevice] = [
        TuyaDevice(id: "demo-bulb", name: "Desk Lamp", ip: "10.0.0.21", version: "3.5", category: "dj", kind: .light,
                   codes: ["switch_led": 20, "work_mode": 21, "bright_value_v2": 22, "temp_value_v2": 23, "colour_data_v2": 24],
                   ranges: ["bright_value_v2": [10, 1000], "temp_value_v2": [0, 1000]], toggles: [.init(dp: "20", name: "Light")]),
        TuyaDevice(id: "demo-strip", name: "TV Backlight", ip: "10.0.0.22", version: "3.5", category: "dd", kind: .light,
                   codes: ["switch_led": 20, "work_mode": 21, "colour_data": 24], toggles: [.init(dp: "20", name: "Light")]),
        TuyaDevice(id: "demo-board", name: "Bedroom", ip: "10.0.0.23", version: "3.3", category: "kg", kind: .switchboard,
                   toggles: [.init(dp: "1", name: "Ceiling Light"), .init(dp: "2", name: "Fan")]),
    ]

    static let demoStates: [String: DeviceState] = [
        "demo-bulb": DeviceState(online: true, toggles: ["20": true], light: LightState(on: true, brightness: 70, warmth: 65, mode: "white")),
        "demo-strip": DeviceState(online: true, toggles: ["20": true], light: LightState(on: true, brightness: 80, mode: "colour", hue: 275)),
        "demo-board": DeviceState(online: true, toggles: ["1": false, "2": true]),
    ]

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
