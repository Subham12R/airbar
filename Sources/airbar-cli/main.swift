import AirCloudKit
import Darwin
import Foundation
import TuyaKit

let version = "1.1.0"

let usage = """
airbar \(version): your Hitachi AC and HomeMate / Tuya lights from the terminal.

AIR CONDITIONER
  airbar status [--json]
  airbar on|off|toggle [--unit NAME]
  airbar set [--unit NAME] [--temp 24.5] [--mode cool|dry|fan|auto|heat] [--fan auto|1-5] [--swing off|vertical|horizontal|both]
  airbar login --phone NUMBER [--country 91]
  airbar login --email ADDRESS
  airbar logout

LIGHTS AND SWITCHES (local, over your Wi-Fi)
  airbar devices [--json]
  airbar light NAME [on|off|toggle] [--brightness 0-100] [--warmth 0-100] [--hue 0-359]
  airbar switch NAME on|off|toggle [--dp N | --all]
  airbar scan
  airbar tuya connect --id ACCESS_ID [--region in]     (asks for the Access Secret)
  airbar tuya import
  airbar tuya add --id DEVICE_ID --name NAME [--ip IP]  (asks for the local key; --key-stdin to pipe it)
  airbar tuya remove NAME
  airbar pair --ssid WIFI_NAME                          (asks for the Wi-Fi password)

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

func findDevice(_ name: String) -> TuyaDevice {
    let all = DeviceStore.load()
    let key = name.lowercased()
    if let d = all.first(where: { $0.id == name || $0.name.lowercased() == key }) { return d }
    let partial = all.filter { $0.name.lowercased().contains(key) }
    if partial.count == 1 { return partial[0] }
    fail(all.isEmpty ? "no lights or switches linked yet. Try: airbar tuya connect, or airbar tuya add"
                     : "no device named \(name). Known: \(all.map(\.name).joined(separator: ", "))")
}

func describe(_ d: TuyaDevice, _ s: DeviceState) -> String {
    guard s.online else { return "\(d.name): unreachable (\(s.error ?? "no reply"))" }
    if let l = s.light {
        var parts = [l.on ? "on" : "off"]
        if l.on, let b = l.brightness { parts.append("\(b)%") }
        if l.on { parts.append(l.mode == "colour" ? "colour \(l.hue ?? 0)°" : "white" + (l.warmth.map { " \($0)% warm" } ?? "")) }
        return "\(d.name): " + parts.joined(separator: ", ")
    }
    let sw = d.toggles.map { "\($0.name) \(s.toggles[$0.dp] == true ? "on" : "off")" }.joined(separator: ", ")
    return "\(d.name): \(sw)"
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

    case "devices", "lights":
        let all = DeviceStore.load()
        if all.isEmpty { print("No lights or switches linked yet."); break }
        let states = await withTaskGroup(of: (String, DeviceState).self) { g in
            for d in all { g.addTask { (d.id, await TuyaControl.state(of: d)) } }
            var out: [String: DeviceState] = [:]
            for await (id, s) in g { out[id] = s }
            return out
        }
        if flag("--json") {
            let rows: [[String: Any]] = all.map { d in
                let s = states[d.id]
                var row: [String: Any] = ["id": d.id, "name": d.name, "kind": d.kind.rawValue, "ip": d.ip, "version": d.version,
                                          "online": s?.online ?? false, "switches": s?.toggles ?? [:]]
                if let l = s?.light {
                    row["light"] = ["on": l.on, "brightness": l.brightness as Any, "warmth": l.warmth as Any, "mode": l.mode as Any, "hue": l.hue as Any]
                }
                return row
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } else {
            for d in all { print(describe(d, states[d.id] ?? DeviceState(online: false))) }
        }

    case "light":
        guard let name = args.first, !name.hasPrefix("--") else { fail("which light? e.g. airbar light \"Desk Lamp\" on", code: 2) }
        args.removeFirst()
        let d = findDevice(name)
        let brightness = option("--brightness").flatMap(Int.init)
        let warmth = option("--warmth").flatMap(Int.init)
        let hue = option("--hue").flatMap(Int.init)
        if let action = args.first, let p = d.powerDP {
            let current = await TuyaControl.state(of: d).toggles[p] ?? false
            switch action {
            case "on": try await TuyaControl.setToggle(d, dp: p, on: true)
            case "off": try await TuyaControl.setToggle(d, dp: p, on: false)
            case "toggle": try await TuyaControl.setToggle(d, dp: p, on: !current)
            default: fail("use on, off or toggle", code: 2)
            }
        }
        if let b = brightness { try await TuyaControl.setBrightness(d, percent: b) }
        if let w = warmth { try await TuyaControl.setWarmth(d, percent: w) }
        if let h = hue { try await TuyaControl.setColour(d, hue: h) }
        print(describe(d, await TuyaControl.state(of: d)))

    case "switch":
        guard args.count >= 2 else { fail("e.g. airbar switch Bedroom on --dp 2", code: 2) }
        let d = findDevice(args.removeFirst())
        let action = args.removeFirst()
        let all = flag("--all")
        let dp = option("--dp") ?? d.toggles.first?.dp
        guard let dp else { fail("\(d.name) has no switches", code: 2) }
        let current = await TuyaControl.state(of: d)
        let on: Bool
        switch action {
        case "on": on = true
        case "off": on = false
        case "toggle": on = !(all ? current.toggles.values.contains(true) : (current.toggles[dp] ?? false))
        default: fail("use on, off or toggle", code: 2)
        }
        if all { try await TuyaControl.setAll(d, on: on) } else { try await TuyaControl.setToggle(d, dp: dp, on: on) }
        print(describe(d, await TuyaControl.state(of: d)))

    case "scan":
        let linked = Set(DeviceStore.load().map(\.id))
        let found = await TuyaDiscovery.scan(seconds: 8)
        if found.isEmpty { print("No Tuya devices heard on this network.") }
        for d in found.sorted(by: { $0.ip < $1.ip }) {
            print("\(d.ip.padding(toLength: 16, withPad: " ", startingAt: 0)) v\(d.version)  \(d.id)\(linked.contains(d.id) ? "  (linked)" : "")")
        }

    case "tuya":
        guard let sub = args.first else { fail("use: tuya connect | import | add | remove", code: 2) }
        args.removeFirst()
        let cloud = TuyaCloud()
        switch sub {
        case "connect":
            guard let id = option("--id") else { fail("pass --id ACCESS_ID (from your Tuya project's Overview)", code: 2) }
            let region = option("--region") ?? "in"
            let secret = flag("--secret-stdin") ? (readLine(strippingNewline: true) ?? "") : readSecret("Access Secret: ")
            try await cloud.connect(accessId: id, accessSecret: secret, region: region,
                                    knownDeviceIds: DeviceStore.load().map(\.id))
            fallthrough
        case "import":
            let found = try await cloud.importDevices(lan: await TuyaDiscovery.scan(seconds: 6))
            for (d, key) in found { try DeviceStore.upsert(d, key: key) }
            print("Imported \(found.count) device\(found.count == 1 ? "" : "s"): \(found.map(\.device.name).joined(separator: ", "))")
        case "add":
            guard let id = option("--id"), let name = option("--name") else { fail("pass --id DEVICE_ID --name NAME", code: 2) }
            let ipArg = option("--ip")
            let key = flag("--key-stdin") ? (readLine(strippingNewline: true) ?? "") : readSecret("Local key: ")
            var ip = ipArg ?? "", ver = "3.5"
            if let hit = await TuyaDiscovery.scan(seconds: 6).first(where: { $0.id == id }) {
                if ip.isEmpty { ip = hit.ip }
                ver = hit.version
            }
            guard !ip.isEmpty else { fail("that device isn't broadcasting here; pass --ip") }
            let dps = try await TuyaLocal.status(id: id, ip: ip, version: TuyaVersion(string: ver) ?? .v35, key: key)
            let d = DeviceRecords.fromStatus(id: id, name: name, ip: ip, version: ver, dps: dps)
            try DeviceStore.upsert(d, key: key)
            print("Added \(name) as a \(d.isLight ? "light" : "switch").")
        case "remove":
            guard let name = args.first else { fail("which device?", code: 2) }
            let d = findDevice(name)
            try DeviceStore.remove(d.id)
            print("Removed \(d.name) and its key.")
        default:
            fail("unknown tuya command \(sub)", code: 2)
        }

    case "pair":
        guard let ssid = option("--ssid") else { fail("pass --ssid WIFI_NAME (2.4 GHz)", code: 2) }
        let password = readSecret("Wi-Fi password for \(ssid): ")
        print("Put the device in pairing mode (light blinking fast). Sending Wi-Fi details for up to 2 minutes…")
        let added = try await Pairing.run(cloud: TuyaCloud(), ssid: ssid, password: password) { event in
            switch event {
            case .joined(_, let name): print("  joined: \(name.isEmpty ? "new device" : name)")
            case .step(_, .failed, let message?): print("  " + message)
            default: break
            }
        }
        print(added.isEmpty ? "Nothing was added." : "Added: \(added.map(\.name).joined(separator: ", "))")

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
