import Foundation
import Security

/// A linked HomeMate / Tuya device. The local key lives in the Keychain, not here.
public struct TuyaDevice: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case light, switchboard = "switch" }
    public struct Toggle: Codable, Hashable, Sendable {
        public var dp: String
        public var name: String
        public init(dp: String, name: String) { self.dp = dp; self.name = name }
    }

    public var id: String
    public var name: String
    public var ip: String
    public var version: String
    public var category: String
    public var productName: String?
    public var kind: Kind
    /// Function code → data point id, e.g. `switch_led → 20`.
    public var codes: [String: Int]
    /// Integer ranges, e.g. `bright_value_v2 → [10, 1000]`.
    public var ranges: [String: [Double]]
    public var toggles: [Toggle]

    public init(id: String, name: String, ip: String, version: String, category: String = "", productName: String? = nil,
                kind: Kind, codes: [String: Int] = [:], ranges: [String: [Double]] = [:], toggles: [Toggle] = []) {
        self.id = id; self.name = name; self.ip = ip; self.version = version; self.category = category
        self.productName = productName; self.kind = kind; self.codes = codes; self.ranges = ranges; self.toggles = toggles
    }

    public var protocolVersion: TuyaVersion { TuyaVersion(string: version) ?? .v35 }
    public var isLight: Bool { kind == .light }

    func dp(_ codes: String...) -> String? {
        for c in codes { if let v = self.codes[c] { return String(v) } }
        return nil
    }

    public var powerDP: String? { dp("switch_led", "switch_1", "switch") ?? toggles.first?.dp }
    public var hasBrightness: Bool { dp("bright_value_v2", "bright_value", "bright_value_1", "colour_data_v2", "colour_data") != nil }
    public var hasWarmth: Bool { dp("temp_value_v2", "temp_value") != nil }
    public var hasColour: Bool { dp("colour_data_v2", "colour_data") != nil }
}

// MARK: - Storage

/// Devices in `~/Library/Application Support/AirBar/devices.json`; keys in the Keychain.
public enum DeviceStore {
    static let service = "io.github.subham12r.airbar"

    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirBar", isDirectory: true).appendingPathComponent("devices.json")
    }

    public static func load() -> [TuyaDevice] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([TuyaDevice].self, from: data)) ?? []
    }

    public static func save(_ devices: [TuyaDevice]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(devices).write(to: fileURL, options: .atomic)
    }

    /// Adds or replaces a device, keeping a name the user gave it before.
    public static func upsert(_ device: TuyaDevice, key: String?) throws {
        var all = load()
        if let i = all.firstIndex(where: { $0.id == device.id }) {
            var d = device
            let renamed = Dictionary(uniqueKeysWithValues: all[i].toggles.map { ($0.dp, $0.name) })
            d.toggles = d.toggles.map { TuyaDevice.Toggle(dp: $0.dp, name: renamed[$0.dp] ?? $0.name) }
            all[i] = d
        } else {
            all.append(device)
        }
        try save(all)
        if let key { setKey(key, for: device.id) }
    }

    public static func remove(_ id: String) throws {
        try save(load().filter { $0.id != id })
        deleteKey(for: id)
    }

    public static func update(_ id: String, _ change: (inout TuyaDevice) -> Void) throws {
        var all = load()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        try save(all)
    }

    // MARK: Keys

    public static func key(for id: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "tuya:\(id)", kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func setKey(_ key: String, for id: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "tuya:\(id)"]
        let data = Data(key.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func deleteKey(for id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: "tuya:\(id)"] as CFDictionary)
    }
}

// MARK: - Building records

public enum DeviceRecords {
    static let lightCategories: Set<String> = ["dj", "dd", "fwd", "dc", "xdd", "fsd", "tgq", "tgkg", "gyd", "sxd"]
    static let lightV2 = ["switch_led": 20, "work_mode": 21, "bright_value_v2": 22, "temp_value_v2": 23, "colour_data_v2": 24]
    static let lightV1 = ["switch_led": 1, "work_mode": 2, "bright_value": 3, "temp_value": 4, "colour_data": 5]

    /// From the cloud's DP mapping (Tuya `specifications`): exact codes and ranges.
    public static func fromMapping(id: String, name: String, ip: String, version: String, category: String,
                                   productName: String?, mapping: [(dp: Int, code: String, type: String, values: [String: Any])]) -> TuyaDevice {
        var codes: [String: Int] = [:], ranges: [String: [Double]] = [:], toggles: [TuyaDevice.Toggle] = []
        for m in mapping {
            codes[m.code] = m.dp
            if m.type.lowercased() == "integer", let lo = (m.values["min"] as? NSNumber)?.doubleValue,
               let hi = (m.values["max"] as? NSNumber)?.doubleValue {
                ranges[m.code] = [lo, hi]
            }
            if m.type.lowercased() == "boolean", m.code.hasPrefix("switch") {
                toggles.append(.init(dp: String(m.dp), name: pretty(m.code)))
            }
        }
        let kind: TuyaDevice.Kind = lightCategories.contains(category) || codes["switch_led"] != nil ? .light : .switchboard
        if kind == .light, let led = codes["switch_led"] { toggles = [.init(dp: String(led), name: "Light")] }
        return TuyaDevice(id: id, name: name, ip: ip, version: version, category: category, productName: productName,
                          kind: kind, codes: codes, ranges: ranges, toggles: toggles.sorted { Int($0.dp)! < Int($1.dp)! })
    }

    /// From a live status read, for devices added by hand with only a local key.
    public static func fromStatus(id: String, name: String, ip: String, version: String, dps: [String: Any]) -> TuyaDevice {
        let isBool = { (k: String) in dps[k] is Bool }
        if isBool("20"), dps["22"] != nil || dps["24"] != nil {
            var codes = lightV2
            if dps["22"] == nil { codes["bright_value_v2"] = nil; codes["temp_value_v2"] = nil }
            return TuyaDevice(id: id, name: name, ip: ip, version: version, kind: .light, codes: codes,
                              toggles: [.init(dp: "20", name: "Light")])
        }
        if isBool("1"), let mode = dps["2"] as? String, ["white", "colour", "scene", "music"].contains(mode) {
            return TuyaDevice(id: id, name: name, ip: ip, version: version, kind: .light, codes: lightV1,
                              toggles: [.init(dp: "1", name: "Light")])
        }
        let switches = dps.keys.compactMap(Int.init).filter { $0 < 20 && isBool(String($0)) }.sorted()
        return TuyaDevice(id: id, name: name, ip: ip, version: version, kind: .switchboard,
                          toggles: switches.map { .init(dp: String($0), name: switches.count == 1 ? "Power" : "Switch \($0)") })
    }

    static func pretty(_ code: String) -> String {
        if code == "switch" { return "Power" }
        if code == "switch_led" { return "Light" }
        return code.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
