import Foundation

// MARK: - Indoor unit

/// One air conditioner (indoor unit) as reported by airCloud.
public struct ACUnit: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var power: String
    public var mode: String
    public var iduTemperature: Double?
    public var roomTemperature: Double?
    public var fanSpeed: String
    public var fanSwing: String
    public var online: Bool
    public var cloudId: String?
    public var humidity: Int?
    public var relativeTemperature: Double?
    public var sysType: Int?
    /// Filled in from the model configuration; drives which controls are offered.
    public var capabilities: Capabilities?

    public var isOn: Bool { power == "ON" }
    public var rules: ModeRules? { capabilities?.byMode[mode] }

    public init(id: String, name: String, power: String = "OFF", mode: String = "COOLING", iduTemperature: Double? = 24,
                roomTemperature: Double? = nil, fanSpeed: String = "AUTO", fanSwing: String = "OFF", online: Bool = true,
                cloudId: String? = nil, humidity: Int? = nil, relativeTemperature: Double? = nil, sysType: Int? = 1,
                capabilities: Capabilities? = nil) {
        self.id = id; self.name = name; self.power = power; self.mode = mode; self.iduTemperature = iduTemperature
        self.roomTemperature = roomTemperature; self.fanSpeed = fanSpeed; self.fanSwing = fanSwing; self.online = online
        self.cloudId = cloudId; self.humidity = humidity; self.relativeTemperature = relativeTemperature
        self.sysType = sysType; self.capabilities = capabilities
    }

    /// Lenient parse of the JSON airCloud sends (ids may be numbers or strings, fields may be null).
    public init?(json d: [String: Any]) {
        guard let rawID = d["id"] else { return nil }
        id = "\(rawID)"
        name = d["name"] as? String ?? "AC"
        power = (d["power"] as? String ?? "OFF").uppercased()
        mode = (d["mode"] as? String ?? "COOLING").uppercased()
        iduTemperature = (d["iduTemperature"] as? NSNumber)?.doubleValue
        roomTemperature = (d["roomTemperature"] as? NSNumber)?.doubleValue
        fanSpeed = (d["fanSpeed"] as? String ?? "AUTO").uppercased()
        fanSwing = (d["fanSwing"] as? String ?? "OFF").uppercased()
        online = (d["online"] as? Bool) ?? true
        cloudId = d["cloudId"] as? String
        humidity = (d["humidity"] as? NSNumber)?.intValue
        relativeTemperature = (d["relativeTemperature"] as? NSNumber)?.doubleValue
        sysType = (d["SysType"] as? NSNumber)?.intValue ?? (d["sysType"] as? NSNumber)?.intValue
    }
}

// MARK: - Model capabilities

/// What a given model accepts, from `rac/model-wise/rac-configuration`.
public struct Capabilities: Codable, Hashable, Sendable {
    public var modes: [String]
    public var swings: [String]
    public var byMode: [String: ModeRules]

    public init(modes: [String], swings: [String], byMode: [String: ModeRules]) {
        self.modes = modes; self.swings = swings; self.byMode = byMode
    }

    static let modeOrder = ["COOLING", "HEATING", "DRY", "DRY_COOL", "FAN", "AUTO"]
    static let fanOrder = ["AUTO", "LV1", "LV2", "LV3", "LV4", "LV5"]

    /// Parses one entry of the rac-configuration response.
    public init?(modelConfig c: [String: Any]) {
        guard let opModes = c["racOperationModes"] as? [[String: Any]] else { return nil }
        let sw = c["swing"] as? [String: Bool] ?? [:]
        var swings = ["OFF"]
        if sw["VERTICAL"] == true { swings.append("VERTICAL") }
        if sw["HORIZONTAL"] == true { swings.append("HORIZONTAL") }
        if sw["VERTICAL"] == true && sw["HORIZONTAL"] == true { swings.append("BOTH") }
        var byMode: [String: ModeRules] = [:]
        var found: [String] = []
        for m in opModes {
            guard let mode = (m["mode"] as? String)?.uppercased(), !mode.isEmpty else { continue }
            found.append(mode)
            let en = m["enableSettings"] as? [String: Bool] ?? [:]
            let enabledFans = m["enableFanSpeed"] as? [String: Bool] ?? [:]
            let fans = Self.fanOrder.filter { enabledFans[$0] == true }
            let defaultFan = (m["defaultFanSpeed"] as? [String: Bool] ?? [:]).first { $0.value }?.key ?? fans.first ?? "AUTO"
            func num(_ k: String) -> Double? { (m[k] as? NSNumber)?.doubleValue }
            byMode[mode] = ModeRules(
                temperature: en["temperature"] ?? false, minTemperature: num("minTemperature"),
                maxTemperature: num("maxTemperature"), temperatureStep: num("temperatureSettingPitchType") ?? 1,
                fans: fans, defaultFan: defaultFan, humidity: en["humidity"] ?? false,
                defaultHumidity: Int(num("defaultHumidity") ?? 0),
                minHumidity: num("minHumidity").map(Int.init), maxHumidity: num("maxHumidity").map(Int.init))
        }
        modes = Self.modeOrder.filter(found.contains) + found.filter { !Self.modeOrder.contains($0) }
        self.swings = swings
        self.byMode = byMode
    }
}

public struct ModeRules: Codable, Hashable, Sendable {
    public var temperature: Bool
    public var minTemperature: Double?
    public var maxTemperature: Double?
    public var temperatureStep: Double
    public var fans: [String]
    public var defaultFan: String
    public var humidity: Bool
    public var defaultHumidity: Int
    public var minHumidity: Int?
    public var maxHumidity: Int?

    public init(temperature: Bool, minTemperature: Double?, maxTemperature: Double?, temperatureStep: Double,
                fans: [String], defaultFan: String, humidity: Bool = false, defaultHumidity: Int = 0,
                minHumidity: Int? = nil, maxHumidity: Int? = nil) {
        self.temperature = temperature; self.minTemperature = minTemperature; self.maxTemperature = maxTemperature
        self.temperatureStep = temperatureStep; self.fans = fans; self.defaultFan = defaultFan; self.humidity = humidity
        self.defaultHumidity = defaultHumidity; self.minHumidity = minHumidity; self.maxHumidity = maxHumidity
    }
}

// MARK: - Commands

/// The full state you want a unit in. Unset fields keep the unit's current value.
public struct DesiredState: Sendable, Equatable {
    public var power: String?
    public var mode: String?
    public var temperature: Double?
    public var fanSpeed: String?
    public var fanSwing: String?

    public init(power: String? = nil, mode: String? = nil, temperature: Double? = nil, fanSpeed: String? = nil, fanSwing: String? = nil) {
        self.power = power; self.mode = mode; self.temperature = temperature; self.fanSpeed = fanSpeed; self.fanSwing = fanSwing
    }

    /// Everything about `unit` as it stands, e.g. to re-send the app's optimistic state.
    public init(of unit: ACUnit) {
        self.init(power: unit.power, mode: unit.mode, temperature: unit.iduTemperature, fanSpeed: unit.fanSpeed, fanSwing: unit.fanSwing)
    }
}

// MARK: - Sign-in

public enum SignInMethod: Sendable, Equatable {
    case email(String)
    /// Country code without "+", and the national number.
    case phone(countryCode: String, number: String)

    /// The JSON field and value airCloud's `iam/auth/sign-in` expects.
    /// Phone accounts sign in with `mobileNumber` in `+<cc><number>` form (seen in the official app).
    public var credentialField: (field: String, value: String, label: String) {
        switch self {
        case .email(let e):
            let v = e.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("email", v, v)
        case .phone(let cc, let number):
            let ccDigits = cc.filter(\.isNumber).isEmpty ? "91" : cc.filter(\.isNumber)
            var digits = number.filter(\.isNumber)
            if digits.hasPrefix(ccDigits), digits.count > 10 { digits.removeFirst(ccDigits.count) }
            while digits.hasPrefix("0") { digits.removeFirst() }
            return ("mobileNumber", "+\(ccDigits)\(digits)", "+\(ccDigits) \(digits)")
        }
    }
}

// MARK: - Errors

public enum AirCloudError: LocalizedError, Equatable {
    case notSignedIn
    case badCredentials
    case busy
    case rejected(String)
    case unsupportedMode(String)
    case noUnit(String)
    case http(Int, String)
    case noState

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to airCloud yet."
        case .badCredentials: return "airCloud didn't recognise that account and password. Check you picked Phone or Email to match how you sign in to the airCloud Go app."
        case .busy: return "The AC is still busy with the previous command. Try again in a moment."
        case .rejected(let what): return "The AC rejected that setting: \(what)"
        case .unsupportedMode(let m): return "This AC doesn't have a \(m.lowercased()) mode."
        case .noUnit(let n): return "No AC named \(n)."
        case .http(let code, let body): return "airCloud returned HTTP \(code)\(body.isEmpty ? "" : ": \(body.prefix(160))")"
        case .noState: return "airCloud didn't send the unit list. Check your connection and try again."
        }
    }
}
