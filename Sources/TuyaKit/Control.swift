import Foundation

public struct LightState: Hashable, Sendable {
    public var on: Bool
    /// 0–100.
    public var brightness: Int?
    /// 0 = coolest white, 100 = warmest.
    public var warmth: Int?
    /// "white", "colour", "scene"…
    public var mode: String?
    /// 0–359 when a colour is set.
    public var hue: Int?

    public init(on: Bool, brightness: Int? = nil, warmth: Int? = nil, mode: String? = nil, hue: Int? = nil) {
        self.on = on; self.brightness = brightness; self.warmth = warmth; self.mode = mode; self.hue = hue
    }
}

public struct DeviceState: Hashable, Sendable {
    public var online: Bool
    public var toggles: [String: Bool]
    public var light: LightState?
    public var error: String?

    public init(online: Bool, toggles: [String: Bool] = [:], light: LightState? = nil, error: String? = nil) {
        self.online = online; self.toggles = toggles; self.light = light; self.error = error
    }
}

/// High-level actions on linked devices: power, brightness, white tone, colour.
public enum TuyaControl {
    static let defaultRanges: [String: [Double]] = ["bright_value_v2": [10, 1000], "temp_value_v2": [0, 1000],
                                                    "bright_value": [25, 255], "temp_value": [0, 255]]

    // MARK: Reading

    public static func state(of device: TuyaDevice) async -> DeviceState {
        do {
            let dps = try await status(device)
            var toggles: [String: Bool] = [:]
            for t in device.toggles { toggles[t.dp] = dps[t.dp] as? Bool ?? false }
            return DeviceState(online: true, toggles: toggles, light: device.isLight ? lightState(device, dps) : nil)
        } catch {
            return DeviceState(online: false, error: error.localizedDescription)
        }
    }

    public static func status(_ device: TuyaDevice) async throws -> [String: Any] {
        try await withRelocation(device) { d, key in
            try await TuyaLocal.status(id: d.id, ip: d.ip, version: d.protocolVersion, key: key)
        }
    }

    static func lightState(_ d: TuyaDevice, _ dps: [String: Any]) -> LightState {
        var s = LightState(on: d.powerDP.flatMap { dps[$0] as? Bool } ?? false)
        if let m = d.dp("work_mode") { s.mode = dps[m] as? String }
        if let (dp, code) = first(d, "temp_value_v2", "temp_value"), let v = number(dps[dp]) {
            s.warmth = 100 - unscale(d, code, v)
        }
        let colour = colourInfo(d, dps)
        if let hsv = colour.flatMap({ parse($0.format, $0.raw) }) { s.hue = hsv.h }
        let bright = first(d, "bright_value_v2", "bright_value", "bright_value_1")
        if let hsv = colour.flatMap({ parse($0.format, $0.raw) }), s.mode == "colour" || bright == nil {
            s.brightness = hsv.v
        } else if let (dp, code) = bright, let v = number(dps[dp]) {
            s.brightness = unscale(d, code, v)
        }
        return s
    }

    // MARK: Writing

    public static func set(_ device: TuyaDevice, dps: [String: Any]) async throws {
        try await withRelocation(device) { d, key in
            try await TuyaLocal.set(id: d.id, ip: d.ip, version: d.protocolVersion, key: key, dps: dps)
        }
    }

    public static func setToggle(_ device: TuyaDevice, dp: String, on: Bool) async throws {
        try await set(device, dps: [dp: on])
    }

    public static func setAll(_ device: TuyaDevice, on: Bool) async throws {
        try await set(device, dps: Dictionary(uniqueKeysWithValues: device.toggles.map { ($0.dp, on as Any) }))
    }

    public static func setBrightness(_ device: TuyaDevice, percent: Int) async throws {
        let power = device.powerDP
        let mode = device.dp("work_mode")
        let bright = first(device, "bright_value_v2", "bright_value", "bright_value_1")
        let dps = try await status(device)
        let inColour = mode.map { dps[$0] as? String == "colour" } ?? false
        var values: [String: Any] = [:]
        if let power { values[power] = true }
        if let c = colourInfo(device, dps), inColour || bright == nil {
            let hsv = parse(c.format, c.raw) ?? (0, 0, 100)
            values[c.dp] = encode(c.format, h: hsv.h, s: hsv.s, v: percent)
            if bright == nil, let mode { values[mode] = "colour" }
        } else if let (dp, code) = bright {
            values[dp] = scale(device, code, percent)
            if let mode { values[mode] = "white" }
        } else {
            throw TuyaError.device("\(device.name) has no brightness control.")
        }
        try await set(device, dps: values)
    }

    public static func setWarmth(_ device: TuyaDevice, percent: Int) async throws {
        guard let (dp, code) = first(device, "temp_value_v2", "temp_value") else {
            throw TuyaError.device("\(device.name) has no white-tone control.")
        }
        var values: [String: Any] = [dp: scale(device, code, 100 - percent)]
        if let p = device.powerDP { values[p] = true }
        if let m = device.dp("work_mode") { values[m] = "white" }
        try await set(device, dps: values)
    }

    public static func setColour(_ device: TuyaDevice, hue: Int, saturation: Int = 100) async throws {
        let dps = try await status(device)
        guard let c = colourInfo(device, dps) else { throw TuyaError.device("\(device.name) has no colour control.") }
        let current = parse(c.format, c.raw)
        let value = (current?.v ?? 0) > 0 ? current!.v : 100
        var values: [String: Any] = [c.dp: encode(c.format, h: hue, s: saturation, v: value)]
        if let p = device.powerDP { values[p] = true }
        if let m = device.dp("work_mode") { values[m] = "colour" }
        try await set(device, dps: values)
    }

    // MARK: Colour formats
    // Codes lie: many strips report `colour_data` but use the 12-character v2 format
    // (HHHH SSSS VVVV, S/V 0–1000). The older 14-character format is RRGGBB HHHH SS VV (S/V 0–255).

    enum ColourFormat { case v1, v2 }

    static func colourInfo(_ d: TuyaDevice, _ dps: [String: Any]) -> (dp: String, format: ColourFormat, raw: String?)? {
        guard let (dp, code) = first(d, "colour_data_v2", "colour_data") else { return nil }
        let raw = dps[dp] as? String
        let format: ColourFormat = raw?.count == 14 ? .v1 : raw?.count == 12 ? .v2 : (code == "colour_data_v2" ? .v2 : .v1)
        return (dp, format, raw)
    }

    static func parse(_ f: ColourFormat, _ raw: String?) -> (h: Int, s: Int, v: Int)? {
        guard let raw else { return nil }
        let c = Array(raw)
        func hex(_ a: Int, _ b: Int) -> Int? { a < b && b <= c.count ? Int(String(c[a..<b]), radix: 16) : nil }
        switch f {
        case .v2:
            guard c.count == 12, let h = hex(0, 4), let s = hex(4, 8), let v = hex(8, 12) else { return nil }
            return (h, Int((Double(s) / 10).rounded()), Int((Double(v) / 10).rounded()))
        case .v1:
            guard c.count == 14, let h = hex(6, 10), let s = hex(10, 12), let v = hex(12, 14) else { return nil }
            return (h, Int((Double(s) / 2.55).rounded()), Int((Double(v) / 2.55).rounded()))
        }
    }

    static func encode(_ f: ColourFormat, h: Int, s: Int, v: Int) -> String {
        let hue = ((h % 360) + 360) % 360, sat = min(100, max(0, s)), val = min(100, max(1, v))
        switch f {
        case .v2:
            return String(format: "%04x%04x%04x", hue, sat * 10, val * 10)
        case .v1:
            let (r, g, b) = hsvToRGB(Double(hue) / 360, Double(sat) / 100, Double(val) / 100)
            return String(format: "%02x%02x%02x%04x%02x%02x", r, g, b, hue,
                          Int((Double(sat) * 2.55).rounded()), Int((Double(val) * 2.55).rounded()))
        }
    }

    static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Int, Int, Int) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    // MARK: Helpers

    static func first(_ d: TuyaDevice, _ codes: String...) -> (dp: String, code: String)? {
        for c in codes { if let v = d.codes[c] { return (String(v), c) } }
        return nil
    }

    static func range(_ d: TuyaDevice, _ code: String) -> (Double, Double) {
        let r = d.ranges[code] ?? defaultRanges[code] ?? [0, 1000]
        return (r[0], r[1])
    }

    static func scale(_ d: TuyaDevice, _ code: String, _ percent: Int) -> Int {
        let (lo, hi) = range(d, code)
        return Int((lo + (hi - lo) * Double(min(100, max(0, percent))) / 100).rounded())
    }

    static func unscale(_ d: TuyaDevice, _ code: String, _ value: Double) -> Int {
        let (lo, hi) = range(d, code)
        return hi > lo ? Int(((value - lo) * 100 / (hi - lo)).rounded()) : 0
    }

    static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    /// If the device moved to a new IP (DHCP), find it by its broadcast, save the new address and retry once.
    static func withRelocation<T>(_ device: TuyaDevice, _ op: (TuyaDevice, String) async throws -> T) async throws -> T {
        guard let key = DeviceStore.key(for: device.id) else { throw TuyaError.noKey(device.name) }
        do {
            return try await op(device, key)
        } catch let e as TuyaError where e == .timeout || { if case .unreachable = e { return true } else { return false } }() {
            guard let found = await TuyaDiscovery.scan(seconds: 6).first(where: { $0.id == device.id }), found.ip != device.ip else { throw e }
            var moved = device
            moved.ip = found.ip
            moved.version = found.version
            try? DeviceStore.update(device.id) { $0.ip = found.ip; $0.version = found.version }
            return try await op(moved, key)
        }
    }
}
