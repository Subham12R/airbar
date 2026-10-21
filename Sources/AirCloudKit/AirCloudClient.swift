import Foundation

/// Client for the Hitachi airCloud Go cloud API (the endpoints the official app uses).
///
/// Being an actor, it sends one request at a time per process; `send` additionally holds a
/// file lock so the menu bar app and the CLI never talk to the same unit at once.
public actor AirCloudClient {
    struct Credentials: Codable { var field: String; var value: String; var password: String; var label: String }
    struct Session: Codable { var token: String; var refreshToken: String?; var issuedAt: Date; var familyId: String }

    public nonisolated let config: AirBarConfig
    private var credentials: Credentials?
    private var session: Session?
    private var modelCache: [String: Capabilities]
    private let http: URLSession
    private static let tokenMaxAge: TimeInterval = 5 * 60

    public init(config: AirBarConfig = .load()) {
        self.config = config
        credentials = Keychain.read(Credentials.self, account: "login")
        session = Keychain.read(Session.self, account: "session")
        modelCache = Self.loadModelCache()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.httpAdditionalHeaders = ["User-Agent": config.userAgent, "Accept": "application/json"]
        http = URLSession(configuration: cfg)
    }

    public var isSignedIn: Bool { credentials != nil }
    public var accountLabel: String? { credentials?.label }

    // MARK: - Auth

    /// Signs in and stores the credentials in the Keychain. Throws `.badCredentials` on 401.
    public func signIn(_ method: SignInMethod, password: String) async throws {
        let (field, value, label) = method.credentialField
        try await authenticate(Credentials(field: field, value: value, password: password, label: label))
    }

    public func signOut() {
        Keychain.delete(account: "login")
        Keychain.delete(account: "session")
        credentials = nil
        session = nil
    }

    private func authenticate(_ c: Credentials) async throws {
        let (code, data) = try await raw("POST", "iam/auth/sign-in", json: [c.field: c.value, "password": c.password])
        guard code == 200 else {
            if code == 401 || code == 403 { throw AirCloudError.badCredentials }
            throw AirCloudError.http(code, String(decoding: data, as: UTF8.self))
        }
        let tokens = try Self.object(data)
        guard let token = tokens["token"] as? String else { throw AirCloudError.http(code, "no token in response") }
        let who = try Self.object(try await rawOK("GET", "iam/user/v2/who-am-i", bearer: token))
        guard let family = who["familyId"] else { throw AirCloudError.http(200, "no familyId in who-am-i") }
        credentials = c
        session = Session(token: token, refreshToken: tokens["refreshToken"] as? String, issuedAt: Date(), familyId: "\(family)")
        Keychain.write(c, account: "login")
        Keychain.write(session!, account: "session")
    }

    private func validSession() async throws -> Session {
        if let s = session, Date().timeIntervalSince(s.issuedAt) < Self.tokenMaxAge { return s }
        if session != nil, (try? await refreshToken()) != nil, let s = session { return s }
        guard let c = credentials else { throw AirCloudError.notSignedIn }
        try await authenticate(c)
        return session!
    }

    private func refreshToken() async throws {
        guard var s = session, let rt = s.refreshToken else { throw AirCloudError.notSignedIn }
        let (code, data) = try await raw("POST", "iam/auth/refresh-token", bearer: rt, headers: ["isRefreshToken": "true"])
        guard code == 200, let t = try? Self.object(data), let token = t["token"] as? String else {
            throw AirCloudError.http(code, "refresh failed")
        }
        s.token = token
        s.refreshToken = t["refreshToken"] as? String ?? s.refreshToken
        s.issuedAt = Date()
        session = s
        Keychain.write(s, account: "session")
    }

    private func reauthenticate() async throws {
        if (try? await refreshToken()) == nil {
            guard let c = credentials else { throw AirCloudError.notSignedIn }
            try await authenticate(c)
        }
    }

    // MARK: - State

    /// All indoor units in the account's home, with their model capabilities attached.
    public func units() async throws -> [ACUnit] {
        var list: [[String: Any]]? = nil
        for _ in 0..<2 {
            let s = try await validSession()
            do {
                guard let units = try await snapshot(token: s.token, familyId: s.familyId) else {
                    try await reauthenticate()   // token rejected by the socket
                    continue
                }
                list = units
            } catch {
                // socket failed: fall back to REST below
            }
            break
        }
        if list == nil {
            let s = try await validSession()
            let data = try await api("GET", "rac/ownership/groups/\(s.familyId)/idu-list")
            let obj = try JSONSerialization.jsonObject(with: data)
            list = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        }
        var units = (list ?? []).compactMap(ACUnit.init(json:))
        try? await loadCapabilities(for: units.compactMap(\.cloudId))
        for i in units.indices { units[i].capabilities = units[i].cloudId.flatMap { modelCache[$0] } }
        return units
    }

    /// One-shot STOMP subscription. Returns nil when the server refused the token.
    private func snapshot(token: String, familyId: String) async throws -> [[String: Any]]? {
        guard let url = URL(string: config.notificationURL) else { throw AirCloudError.noState }
        var req = URLRequest(url: url)
        req.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        let task = http.webSocketTask(with: req)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await task.send(.string(STOMP.connectAndSubscribe(token: token, familyId: familyId)))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let message = try await withTimeout(seconds: deadline.timeIntervalSinceNow) { try await task.receive() }
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            switch STOMP.parse(text) {
            case .connected(let ok): if !ok { return nil }
            case .units(let list): return list
            case .other: continue
            }
        }
        throw AirCloudError.noState
    }

    // MARK: - Model rules

    public func capabilities(for unit: ACUnit) async throws -> Capabilities? {
        guard let cid = unit.cloudId else { return nil }
        if modelCache[cid] == nil { try await loadCapabilities(for: [cid]) }
        return modelCache[cid]
    }

    private func loadCapabilities(for cloudIds: [String]) async throws {
        let missing = Array(Set(cloudIds.filter { modelCache[$0] == nil }))
        guard !missing.isEmpty else { return }
        let data = try await api("POST", "rac/model-wise/rac-configuration", json: missing)
        let obj = try JSONSerialization.jsonObject(with: data)
        let list = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        for cfg in list {
            if let cid = cfg["cloudId"] as? String, let caps = Capabilities(modelConfig: cfg) { modelCache[cid] = caps }
        }
        Self.saveModelCache(modelCache)
    }

    // MARK: - Control

    /// Sends `desired` to `unit` (fitted to the model's rules) and returns the unit as commanded.
    @discardableResult
    public func send(_ desired: DesiredState, to unit: ACUnit) async throws -> ACUnit {
        let caps: Capabilities?
        if let known = unit.capabilities { caps = known } else { caps = try? await capabilities(for: unit) }
        let body = try CommandFitting.body(for: desired, unit: unit, capabilities: caps)
        let s = try await validSession()
        let path = "rac/basic-idu-control/general-control-command/\(unit.id)?familyId=\(s.familyId)"
        let lock = try await FileLock.acquire(AirBarConfig.directory.appendingPathComponent("commands.lock"))
        defer { lock.release() }
        _ = try await api("PUT", path, json: body)
        try? await Task.sleep(nanoseconds: UInt64(config.settleSeconds * 1_000_000_000))
        var updated = unit
        updated.power = body["power"] as? String ?? unit.power
        updated.mode = body["mode"] as? String ?? unit.mode
        updated.fanSpeed = body["fanSpeed"] as? String ?? unit.fanSpeed
        updated.fanSwing = body["fanSwing"] as? String ?? unit.fanSwing
        if let t = body["iduTemperature"] as? Double { updated.iduTemperature = t }
        return updated
    }

    // MARK: - HTTP

    /// Authenticated call with token refresh, `429 command_in_progress` back-off and readable errors.
    private func api(_ method: String, _ path: String, json: Any? = nil) async throws -> Data {
        var s = try await validSession()
        var (code, data) = try await raw(method, path, json: json, bearer: s.token)
        if code == 401 || code == 403 {
            try await reauthenticate()
            s = try await validSession()
            (code, data) = try await raw(method, path, json: json, bearer: s.token)
        }
        var delay = 1.0
        for _ in 0..<8 where code == 429 && String(decoding: data, as: UTF8.self).contains("command_in_progress") {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 1.4, 3)
            (code, data) = try await raw(method, path, json: json, bearer: s.token)
        }
        switch code {
        case 200..<300: return data
        case 429: throw AirCloudError.busy
        case 400 where path.contains("general-control-command"):
            throw AirCloudError.rejected(Self.describe(json))
        default: throw AirCloudError.http(code, String(decoding: data, as: UTF8.self))
        }
    }

    private func rawOK(_ method: String, _ path: String, bearer: String) async throws -> Data {
        let (code, data) = try await raw(method, path, bearer: bearer)
        guard (200..<300).contains(code) else { throw AirCloudError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    private func raw(_ method: String, _ path: String, json: Any? = nil, bearer: String? = nil,
                     headers: [String: String] = [:]) async throws -> (Int, Data) {
        guard let url = URL(string: config.apiBaseURL + path) else { throw AirCloudError.http(0, "bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await http.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    // MARK: - Helpers

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AirCloudError.http(200, "unexpected response")
        }
        return o
    }

    private static func describe(_ json: Any?) -> String {
        guard let d = json as? [String: Any] else { return "unknown" }
        return ["mode", "iduTemperature", "fanSpeed", "fanSwing"].compactMap { k in d[k].map { "\(k)=\($0)" } }.joined(separator: ", ")
    }

    private static var modelCacheURL: URL { AirBarConfig.directory.appendingPathComponent("models.json") }

    private static func loadModelCache() -> [String: Capabilities] {
        guard let data = try? Data(contentsOf: modelCacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Capabilities].self, from: data)) ?? [:]
    }

    private static func saveModelCache(_ cache: [String: Capabilities]) {
        try? FileManager.default.createDirectory(at: AirBarConfig.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: modelCacheURL, options: .atomic)
    }
}

/// Races `operation` against a timeout.
func withTimeout<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
            throw AirCloudError.noState
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

/// Advisory cross-process lock (flock) on a file.
final class FileLock: @unchecked Sendable {
    private let fd: Int32
    private init(fd: Int32) { self.fd = fd }

    static func acquire(_ url: URL) async throws -> FileLock {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AirCloudError.http(0, "cannot open lock file") }
        await Task.detached { _ = flock(fd, LOCK_EX) }.value  // may wait for another process
        return FileLock(fd: fd)
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
