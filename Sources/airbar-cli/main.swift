import AirCloudKit
import Darwin
import Foundation

let version = "1.0.0"

let usage = """
airbar \(version): control Hitachi airCloud Go air conditioners from the terminal.

USAGE
  airbar status [--json]
  airbar on|off|toggle [--unit NAME]
  airbar set [--unit NAME] [--temp 24.5] [--mode cool|dry|fan|auto|heat] [--fan auto|1-5] [--swing off|vertical|horizontal|both]
  airbar login --phone NUMBER [--country 91]
  airbar login --email ADDRESS
  airbar logout
  airbar config [--path]

Values your unit's model doesn't support are adjusted to the nearest allowed one.
Config: \(AirBarConfig.fileURL.path)
"""

// MARK: - Argument helpers

var args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("airbar: \(message)\n".utf8))
    exit(code)
}

func readSecret(_ prompt: String) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    guard let p = readpassphrase(prompt, &buf, buf.count, 0) else { fail("couldn't read the password") }
    return String(cString: p)
}

let modeAliases = ["cool": "COOLING", "cooling": "COOLING", "heat": "HEATING", "heating": "HEATING", "dry": "DRY",
                   "dry-cool": "DRY_COOL", "dry_cool": "DRY_COOL", "fan": "FAN", "auto": "AUTO"]
let fanAliases = ["auto": "AUTO", "1": "LV1", "2": "LV2", "3": "LV3", "4": "LV4", "5": "LV5",
                  "low": "LV1", "medium": "LV3", "high": "LV5"]
let swingAliases = ["off": "OFF", "fixed": "OFF", "vertical": "VERTICAL", "up-down": "VERTICAL",
                    "horizontal": "HORIZONTAL", "side": "HORIZONTAL", "both": "BOTH", "all": "BOTH"]

func describe(_ u: ACUnit) -> String {
    let temp = u.rules?.temperature == false ? "fan only" : u.iduTemperature.map { String(format: "%g°", $0) } ?? "—"
    let room = u.roomTemperature.map { String(format: ", room %.1f°", $0) } ?? ""
    let fan = u.fanSpeed.hasPrefix("LV") ? "fan \(u.fanSpeed.dropFirst(2))" : "fan \(u.fanSpeed.lowercased())"
    return "\(u.name): \(u.isOn ? "on" : "off"), \(u.mode.lowercased()) \(temp), \(fan), swing \(u.fanSwing.lowercased())\(room)\(u.online ? "" : " (offline)")"
}

func pick(_ units: [ACUnit], _ name: String?) -> ACUnit {
    if let name {
        let key = name.lowercased()
        if let u = units.first(where: { $0.id == name || $0.name.lowercased() == key }) { return u }
        fail("no AC named \(name). Known: \(units.map(\.name).joined(separator: ", "))")
    }
    guard let only = units.first else { fail("no air conditioners in this airCloud home") }
    if units.count > 1 { fail("several ACs found, pass --unit. Known: \(units.map(\.name).joined(separator: ", "))", code: 2) }
    return only
}

// MARK: - Commands

guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()
if ["-h", "--help", "help"].contains(command) { print(usage); exit(0) }
if ["-v", "--version", "version"].contains(command) { print(version); exit(0) }

let client = AirCloudClient()

do {
    switch command {
    case "status":
        let units = try await client.units()
        if flag("--json") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try enc.encode(units), as: UTF8.self))
        } else if units.isEmpty {
            print("Signed in as \(await client.accountLabel ?? "?"), but the home has no air conditioners.")
        } else {
            units.forEach { print(describe($0)) }
        }

    case "on", "off", "toggle":
        let unit = pick(try await client.units(), option("--unit"))
        let power = command == "toggle" ? (unit.isOn ? "OFF" : "ON") : command.uppercased()
        print(describe(try await client.send(DesiredState(power: power), to: unit)))

    case "set":
        let unit = pick(try await client.units(), option("--unit"))
        var d = DesiredState()
        if let t = option("--temp") {
            guard let v = Double(t) else { fail("--temp needs a number, like 24.5", code: 2) }
            d.temperature = v
        }
        if let m = option("--mode") {
            guard let v = modeAliases[m.lowercased()] else { fail("unknown mode \(m)", code: 2) }
            d.mode = v; d.power = "ON"
        }
        if let f = option("--fan") {
            guard let v = fanAliases[f.lowercased()] else { fail("unknown fan speed \(f)", code: 2) }
            d.fanSpeed = v
        }
        if let s = option("--swing") {
            guard let v = swingAliases[s.lowercased()] else { fail("unknown swing \(s)", code: 2) }
            d.fanSwing = v
        }
        guard d != DesiredState() else { fail("nothing to set. Try --temp, --mode, --fan or --swing", code: 2) }
        print(describe(try await client.send(d, to: unit)))

    case "login":
        let method: SignInMethod
        if let phone = option("--phone") {
            method = .phone(countryCode: option("--country") ?? client.config.defaultCountryCode, number: phone)
        } else if let email = option("--email") {
            method = .email(email)
        } else {
            fail("use --phone NUMBER or --email ADDRESS", code: 2)
        }
        try await client.signIn(method, password: readSecret("airCloud Go password: "))
        let units = try await client.units()
        print("Signed in as \(method.credentialField.label). \(units.count) air conditioner\(units.count == 1 ? "" : "s") found.")
        units.forEach { print("  " + describe($0)) }

    case "logout":
        await client.signOut()
        print("Signed out. Credentials removed from the Keychain.")

    case "config":
        if flag("--path") { print(AirBarConfig.fileURL.path); break }
        _ = AirBarConfig.load()
        print(AirBarConfig.fileURL.path)
        print((try? String(contentsOf: AirBarConfig.fileURL, encoding: .utf8)) ?? "")

    default:
        fail("unknown command \(command)\n\n\(usage)", code: 2)
    }
} catch {
    fail(error.localizedDescription)
}
