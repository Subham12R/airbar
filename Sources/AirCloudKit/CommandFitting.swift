import Foundation

/// Turns a desired state into a control-command body the unit's model accepts.
///
/// airCloud answers `400` for any value the model doesn't support (a fan level a mode doesn't
/// allow, a swing axis the unit lacks, a temperature off the model's step). Rather than surface
/// that, commands are fitted to the model rules first.
public enum CommandFitting {
    static let legacyFan = ["LOW": "LV1", "MEDIUM": "LV3", "HIGH": "LV5",
                            "1": "LV1", "2": "LV2", "3": "LV3", "4": "LV4", "5": "LV5"]
    static let noHumidity = 2_147_483_647

    public static func body(for desired: DesiredState, unit: ACUnit, capabilities caps: Capabilities?) throws -> [String: Any] {
        var power = (desired.power ?? unit.power).uppercased()
        let mode = (desired.mode ?? unit.mode).uppercased()
        var fan = (desired.fanSpeed ?? unit.fanSpeed).uppercased()
        fan = legacyFan[fan] ?? fan
        var swing = (desired.fanSwing ?? unit.fanSwing).uppercased()
        var temperature = desired.temperature ?? unit.iduTemperature
        if desired.temperature != nil && desired.power == nil { power = "ON" }

        var body: [String: Any] = ["power": power, "mode": mode, "fanSpeed": fan, "fanSwing": swing]

        guard let caps else {  // model rules unknown: send as asked
            if mode != "FAN", let t = temperature { body["iduTemperature"] = t }
            return body
        }
        guard caps.modes.contains(mode), let rules = caps.byMode[mode] else { throw AirCloudError.unsupportedMode(mode) }

        if !rules.fans.isEmpty && !rules.fans.contains(fan) { fan = rules.defaultFan }
        if !caps.swings.contains(swing) {
            swing = (swing == "BOTH" && caps.swings.contains("VERTICAL")) ? "VERTICAL" : "OFF"
        }
        body["fanSpeed"] = fan
        body["fanSwing"] = swing

        if rules.temperature {
            let lo = rules.minTemperature ?? 16, hi = rules.maxTemperature ?? 32
            let step = rules.temperatureStep > 0 ? rules.temperatureStep : 1
            let t = temperature ?? lo
            temperature = min(hi, max(lo, (t / step).rounded() * step))
            body["iduTemperature"] = temperature
        }

        // Residential units (SysType 1) expect a humidity value the model accepts in every command.
        if unit.sysType == nil || unit.sysType == 1 {
            var humidity = rules.defaultHumidity
            if rules.humidity, let raw = unit.humidity, raw < noHumidity {
                let inRange = (rules.minHumidity.map { raw >= $0 } ?? true) && (rules.maxHumidity.map { raw <= $0 } ?? true)
                if inRange { humidity = raw }
            }
            body["humidity"] = String(humidity)
            let relative: Double = mode == "AUTO" ? (unit.relativeTemperature ?? 0) : 0
            body["relativeTemperature"] = relative
        }
        return body
    }
}
