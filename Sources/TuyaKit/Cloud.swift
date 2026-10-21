import Foundation
import Security

/// Tuya IoT developer-project access (iot.tuya.com): local keys, DP mappings and pairing tokens.
///
/// HomeMate's own app won't share devices with other apps, so AirBar uses a free Tuya Cloud project
/// that the user links to their Smart Life account once. After that, control stays local.
public actor TuyaCloud {
    public struct Credentials: Codable, Sendable {
        public var accessId: String
        public var accessSecret: String
        public var region: String
        public var uid: String?
        public init(accessId: String, accessSecret: String, region: String, uid: String? = nil) {
            self.accessId = accessId; self.accessSecret = accessSecret; self.region = region; self.uid = uid
        }
    }

    public static let regions: [(id: String, name: String, host: String)] = [
        ("in", "India", "openapi.tuyain.com"), ("sg", "Singapore", "openapi-sg.iotbing.com"),
        ("eu", "Central Europe", "openapi.tuyaeu.com"), ("eu-w", "Western Europe", "openapi-weaz.tuyaeu.com"),
        ("us", "Western America", "openapi.tuyaus.com"), ("us-e", "Eastern America", "openapi-ueaz.tuyaus.com"),
        ("cn", "China", "openapi.tuyacn.com"),
    ]

    public private(set) var credentials: Credentials?
    private var token: (value: String, expires: Date)?
    private let http = URLSession(configuration: .ephemeral)

    public init() { credentials = Self.loadCredentials() }

    public var isConnected: Bool { credentials?.uid != nil }

    // MARK: Connecting

    /// Checks the project credentials, finds the linked Smart Life user and saves everything.
    public func connect(accessId: String, accessSecret: String, region: String, knownDeviceIds: [String]) async throws {
        var c = Credentials(accessId: accessId.trimmingCharacters(in: .whitespaces),
                            accessSecret: accessSecret.trimmingCharacters(in: .whitespaces), region: region)
        credentials = c
        token = nil
        _ = try await accessToken()
        // A device in the linked account reveals its owner; otherwise ask the project for its linked users.
        for id in knownDeviceIds {
            if let info = try? await request("GET", "/v1.0/devices/\(id)") as? [String: Any], let uid = info["uid"] as? String {
                c.uid = uid
                break
            }
        }
        if c.uid == nil, let users = try? await request("GET", "/v1.0/iot-01/associated-users/actions/authorized-apps") as? [[String: Any]] {
            c.uid = users.first?["uid"] as? String
        }
        guard c.uid != nil else {
            credentials = nil
            throw TuyaError.device("Connected to the project, but no Smart Life account is linked yet. In the project open Devices → Link App Account, scan the QR with Smart Life, then try again.")
        }
        credentials = c
        Self.saveCredentials(c)
    }

    public func disconnect() {
        credentials = nil
        token = nil
        Self.deleteCredentials()
    }

    // MARK: Devices

    /// All Wi-Fi devices in the linked account, with local keys and DP mappings, as records ready to save.
    public func importDevices(lan: [DiscoveredDevice]) async throws -> [(device: TuyaDevice, key: String)] {
        guard let uid = credentials?.uid else { throw TuyaError.device("Tuya Cloud isn't connected.") }
        let list = try await request("GET", "/v1.0/users/\(uid)/devices") as? [[String: Any]] ?? []
        var out: [(TuyaDevice, String)] = []
        for d in list {
            guard let id = d["id"] as? String, let key = d["local_key"] as? String, !key.isEmpty, (d["sub"] as? Bool) != true else { continue }
            let hit = lan.first { $0.id == id }
            let mapping = (try? await specification(id)) ?? []
            let device = DeviceRecords.fromMapping(id: id, name: d["name"] as? String ?? "Device", ip: hit?.ip ?? (d["ip"] as? String ?? ""),
                                                   version: hit?.version ?? "3.5", category: d["category"] as? String ?? "",
                                                   productName: d["product_name"] as? String, mapping: mapping)
            out.append((device, key))
        }
        return out
    }

    func specification(_ id: String) async throws -> [(dp: Int, code: String, type: String, values: [String: Any])] {
        guard let spec = try await request("GET", "/v1.1/devices/\(id)/specifications") as? [String: Any] else { return [] }
        var seen = Set<Int>()
        var out: [(Int, String, String, [String: Any])] = []
        for item in (spec["status"] as? [[String: Any]] ?? []) + (spec["functions"] as? [[String: Any]] ?? []) {
            guard let dp = (item["dp_id"] as? NSNumber)?.intValue, let code = item["code"] as? String, !seen.contains(dp) else { continue }
            seen.insert(dp)
            var values: [String: Any] = [:]
            if let s = item["values"] as? String, let d = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { values = obj }
            out.append((dp, code, item["type"] as? String ?? "", values))
        }
        return out
    }

    // MARK: Pairing

    /// A one-time token a device in pairing mode uses to register with the linked account.
    public func pairingToken(timeZone: String = TimeZone.current.identifier) async throws -> (token: String, tokenGroup: String) {
        guard let uid = credentials?.uid else { throw TuyaError.device("Tuya Cloud isn't connected.") }
        guard let r = try await request("POST", "/v1.0/device/paring/token",
                                        body: ["paring_type": "EZ", "uid": uid, "time_zone_id": timeZone]) as? [String: Any],
              let token = r["token"] as? String, let region = r["region"] as? String, let secret = r["secret"] as? String else {
            throw TuyaError.device("Tuya Cloud didn't return a pairing token.")
        }
        return (token, region + token + secret)
    }

    /// Devices that joined with `token` so far, and whether any failed.
    public func pairingResult(token: String) async throws -> (joined: [(id: String, name: String)], failed: Bool) {
        let r = try await request("GET", "/v1.0/device/paring/tokens/\(token)") as? [String: Any] ?? [:]
        let ok = (r["success_devices"] as? [[String: Any]] ?? []).compactMap { d -> (String, String)? in
            guard let id = d["id"] as? String else { return nil }
            return (id, d["name"] as? String ?? "")
        }
        return (ok, !(r["error_devices"] as? [Any] ?? []).isEmpty)
    }

    // MARK: Signed requests

    private var host: String { Self.regions.first { $0.id == credentials?.region }?.host ?? "openapi.tuyain.com" }

    private func accessToken() async throws -> String {
        if let t = token, t.expires > Date() { return t.value }
        let r = try await send("GET", "/v1.0/token?grant_type=1", body: nil, token: nil)
        guard let result = r as? [String: Any], let value = result["access_token"] as? String else {
            throw TuyaError.device("Tuya Cloud didn't return an access token.")
        }
        let ttl = (result["expire_time"] as? NSNumber)?.doubleValue ?? 3600
        token = (value, Date().addingTimeInterval(ttl - 60))
        return value
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any? {
        try await send(method, path, body: body, token: try await accessToken())
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?, token: String?) async throws -> Any? {
        guard let c = credentials, let url = URL(string: "https://\(host)\(path)") else { throw TuyaError.device("Tuya Cloud isn't set up.") }
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let t = String(Int(Date().timeIntervalSince1970 * 1000))
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body == nil ? nil : bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in Self.signedHeaders(clientId: c.accessId, secret: c.accessSecret, token: token, t: t,
                                         method: method, path: path, body: bodyData) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, _) = try await http.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TuyaError.device("Tuya Cloud sent an unreadable reply.") }
        guard obj["success"] as? Bool == true else {
            throw TuyaError.device("Tuya Cloud: \(obj["msg"] as? String ?? "request failed") (code \(obj["code"] ?? "?"))")
        }
        return obj["result"]
    }

    /// Tuya's HMAC-SHA256 request signature (the "new" algorithm used by the official SDKs).
    static func signedHeaders(clientId: String, secret: String, token: String?, t: String,
                              method: String, path: String, body: Data) -> [String: String] {
        let stringToSign = "\(method)\n\(TuyaCrypto.sha256Hex(body))\n\n\(path)"
        let message = clientId + (token ?? "") + t + stringToSign
        let sign = TuyaCrypto.hmacSHA256(Data(message.utf8), key: Data(secret.utf8)).hex.uppercased()
        var h = ["client_id": clientId, "sign": sign, "t": t, "sign_method": "HMAC-SHA256"]
        if let token { h["access_token"] = token }
        return h
    }

    // MARK: Keychain

    private static let account = "tuya-cloud"

    static func loadCredentials() -> Credentials? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: DeviceStore.service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: d)
    }

    static func saveCredentials(_ c: Credentials) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        deleteCredentials()
        SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: DeviceStore.service,
                    kSecAttrAccount as String: account, kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    }

    static func deleteCredentials() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: DeviceStore.service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

// MARK: - Pairing flow

public enum PairingStep: String, Sendable { case token, broadcast, joined, key, done }
public enum PairingEvent: Sendable {
    case step(PairingStep, state: StepState, message: String? = nil)
    case progress(elapsed: Int, total: Int)
    case joined(id: String, name: String)
    public enum StepState: Sendable { case active, done, failed }
}

public enum Pairing {
    /// EZ-mode pairing: token → broadcast Wi-Fi details → wait for devices → save them with local keys.
    public static func run(cloud: TuyaCloud, ssid: String, password: String, timeout: Int = 120,
                           onEvent: @escaping @Sendable (PairingEvent) -> Void) async throws -> [TuyaDevice] {
        onEvent(.step(.token, state: .active))
        let (token, tokenGroup) = try await cloud.pairingToken()
        onEvent(.step(.token, state: .done))

        let stop = StopFlag()
        let ip = localIPv4()
        let sender = Task.detached(priority: .userInitiated) {
            SmartConfig.transmit(ssid: ssid, password: password, tokenGroup: tokenGroup, bindIP: ip) { stop.isSet }
        }
        defer { stop.set() }
        onEvent(.step(.broadcast, state: .active))

        var joined: [String: String] = [:]
        let start = Date()
        while Int(Date().timeIntervalSince(start)) < timeout {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            try Task.checkCancellation()
            onEvent(.progress(elapsed: Int(Date().timeIntervalSince(start)), total: timeout))
            guard let r = try? await cloud.pairingResult(token: token) else { continue }
            for d in r.joined where joined[d.id] == nil {
                joined[d.id] = d.name
                onEvent(.joined(id: d.id, name: d.name))
                onEvent(.step(.joined, state: .done))
            }
            if r.failed { onEvent(.step(.joined, state: .failed, message: "A device tried to join but failed. Check the Wi-Fi password and that the network is 2.4 GHz.")) }
            if !joined.isEmpty, Date().timeIntervalSince(start) > 20 { break }
        }
        stop.set()
        await sender.value
        guard !joined.isEmpty else {
            onEvent(.step(.broadcast, state: .failed, message: "No device joined. Check it's blinking fast, the password is right and the network is 2.4 GHz."))
            return []
        }
        onEvent(.step(.broadcast, state: .done))
        onEvent(.step(.key, state: .active))
        try await Task.sleep(nanoseconds: 4_000_000_000)  // let it announce itself on the LAN
        let lan = await TuyaDiscovery.scan(seconds: 6)
        var added: [TuyaDevice] = []
        for (device, key) in try await cloud.importDevices(lan: lan) where joined[device.id] != nil {
            try DeviceStore.upsert(device, key: key)
            added.append(device)
        }
        onEvent(.step(.key, state: .done))
        onEvent(.step(.done, state: .done))
        return added
    }

    /// The Mac's IPv4 address on the default route, so multicast goes out of the right interface.
    static func localIPv4() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(UInt16(1).bigEndian)
        inet_pton(AF_INET, "10.255.255.255", &remote.sin_addr)
        let ok = withUnsafePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return nil }
        var local = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}

final class StopFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
