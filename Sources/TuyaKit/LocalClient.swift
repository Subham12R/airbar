import Foundation
import Network

/// Talks to one Tuya device directly over your Wi-Fi (TCP port 6668). No cloud involved.
///
/// Each call opens a connection, negotiates a session key (v3.4 / v3.5), does its work and
/// closes, which keeps things simple and matches how the devices expect short-lived clients.
public enum TuyaLocal {
    public static let port: UInt16 = 6668

    /// Current data points, e.g. `["20": true, "22": 500]`.
    public static func status(id: String, ip: String, version: TuyaVersion, key: String) async throws -> [String: Any] {
        try await withSession(ip: ip, version: version, key: key) { s in
            switch version {
            case .v34, .v35:
                try await s.send(cmd: TuyaCommand.dpQueryNew.rawValue, json: [:])
            case .v33:
                try await s.send(cmd: TuyaCommand.dpQuery.rawValue,
                                 json: ["gwId": id, "devId": id, "uid": id, "t": String(Int(Date().timeIntervalSince1970))])
            }
            for _ in 0..<4 {
                let frame = try await s.receive()
                if let dps = dataPoints(frame.payload) { return dps }
            }
            throw TuyaError.badFrame("no status in reply")
        }
    }

    /// Sets data points, e.g. `["20": true, "22": 800]`.
    public static func set(id: String, ip: String, version: TuyaVersion, key: String, dps: [String: Any]) async throws {
        try await withSession(ip: ip, version: version, key: key) { s in
            switch version {
            case .v34, .v35:
                try await s.send(cmd: TuyaCommand.controlNew.rawValue,
                                 json: ["protocol": 5, "t": Int(Date().timeIntervalSince1970), "data": ["dps": dps]])
            case .v33:
                try await s.send(cmd: TuyaCommand.control.rawValue,
                                 json: ["devId": id, "uid": id, "t": String(Int(Date().timeIntervalSince1970)), "dps": dps])
            }
            _ = try? await s.receive(timeout: 2)  // acknowledgement; harmless if it doesn't come
        }
    }

    static func dataPoints(_ payload: Data) -> [String: Any]? {
        guard !payload.isEmpty, let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        if let dps = obj["dps"] as? [String: Any] { return dps }
        if let data = obj["data"] as? [String: Any], let dps = data["dps"] as? [String: Any] { return dps }
        return nil
    }

    private static func withSession<T>(ip: String, version: TuyaVersion, key: String,
                                       _ body: (Session) async throws -> T) async throws -> T {
        guard let localKey = key.data(using: .utf8), localKey.count == 16 else { throw TuyaError.noKey("this device (keys are 16 characters)") }
        let link = TCPLink(host: ip, port: port)
        defer { link.close() }
        try await link.open(timeout: 4)
        let session = Session(link: link, version: version, localKey: localKey)
        if version.negotiatesSession { try await session.negotiate() }
        return try await body(session)
    }
}

/// One authenticated conversation with a device.
final class Session: @unchecked Sendable {
    let link: TCPLink
    let version: TuyaVersion
    let localKey: Data
    private(set) var key: Data
    private var seq: UInt32 = 1

    init(link: TCPLink, version: TuyaVersion, localKey: Data) {
        self.link = link
        self.version = version
        self.localKey = localKey
        key = localKey
    }

    func send(cmd: UInt32, json: [String: Any]) async throws {
        try await send(cmd: cmd, payload: try JSONSerialization.data(withJSONObject: json))
    }

    func send(cmd: UInt32, payload: Data) async throws {
        let frame = try FrameCodec.encode(cmd: cmd, payload: payload, seq: seq, version: version, key: key)
        seq += 1
        try await link.send(frame)
    }

    func receive(timeout: TimeInterval = 5) async throws -> TuyaFrame {
        try FrameCodec.decode(try await link.readFrame(timeout: timeout), version: version, key: key)
    }

    /// v3.4 / v3.5 session-key exchange: nonces in both directions, HMAC-checked, then mixed into a session key.
    func negotiate() async throws {
        let localNonce = TuyaCrypto.random(16)
        try await send(cmd: TuyaCommand.sessionStart.rawValue, payload: localNonce)
        let reply = try await receive()
        guard reply.cmd == TuyaCommand.sessionResponse.rawValue, reply.payload.count >= 48 else {
            throw TuyaError.handshake("unexpected reply \(reply.cmd)")
        }
        let p = reply.payload
        let remoteNonce = p.prefix(16)
        guard p[p.startIndex + 16 ..< p.startIndex + 48] == TuyaCrypto.hmacSHA256(localNonce, key: localKey) else {
            throw TuyaError.handshake("HMAC mismatch")
        }
        try await send(cmd: TuyaCommand.sessionFinish.rawValue, payload: TuyaCrypto.hmacSHA256(Data(remoteNonce), key: localKey))
        key = try Self.sessionKey(localNonce: localNonce, remoteNonce: Data(remoteNonce), localKey: localKey, version: version)
    }

    static func sessionKey(localNonce: Data, remoteNonce: Data, localKey: Data, version: TuyaVersion) throws -> Data {
        let mixed = Data(zip(localNonce, remoteNonce).map { $0 ^ $1 })
        switch version {
        case .v35: return try TuyaCrypto.gcmSeal(mixed, key: localKey, iv: localNonce.prefix(12), aad: Data()).ciphertext
        default: return try TuyaCrypto.ecbEncrypt(mixed, key: localKey, pad: false)
        }
    }
}

/// A TCP connection that hands back complete Tuya frames.
final class TCPLink: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    private let queue = DispatchQueue(label: "airbar.tuya.tcp")

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func open(timeout: TimeInterval) async throws {
        try await withDeadline(timeout, onTimeout: { [connection] in connection.cancel() }) { [connection, queue] in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = Once()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { cont.resume() }
                    case .failed(let e), .waiting(let e): once.run { cont.resume(throwing: TuyaError.unreachable(e.localizedDescription)) }
                    case .cancelled: once.run { cont.resume(throwing: TuyaError.unreachable("cancelled")) }
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: TuyaError.unreachable(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    func readFrame(timeout: TimeInterval) async throws -> Data {
        try await withDeadline(timeout, onTimeout: { [connection] in connection.cancel() }) { [self] in
            while true {
                // Skip anything before a frame prefix.
                if let start = Self.prefixOffset(in: buffer), start > 0 { buffer.removeFirst(start) }
                if let total = try? FrameCodec.totalLength(buffer), buffer.count >= total {
                    let frame = buffer.prefix(total)
                    buffer.removeFirst(total)
                    return Data(frame)
                }
                buffer += try await receiveChunk()
            }
        }
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, done, error in
                if let error { cont.resume(throwing: TuyaError.unreachable(error.localizedDescription)) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if done { cont.resume(throwing: TuyaError.unreachable("connection closed")) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    static func prefixOffset(in data: Data) -> Int? {
        let a: [UInt8] = [0, 0, 0x55, 0xAA], b: [UInt8] = [0, 0, 0x66, 0x99]
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        for i in 0...(bytes.count - 4) where Array(bytes[i..<i + 4]) == a || Array(bytes[i..<i + 4]) == b { return i }
        return nil
    }

    func close() { connection.cancel() }
}

final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}

/// Runs `op` with a time limit. `onTimeout` must make `op` finish (e.g. cancel its connection),
/// because a task group always waits for its children.
func withDeadline<T: Sendable>(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void = {},
                               _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
            onTimeout()
            throw TuyaError.timeout
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
