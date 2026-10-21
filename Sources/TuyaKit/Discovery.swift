import Darwin
import Foundation

/// A Tuya device announcing itself on the local network.
public struct DiscoveredDevice: Hashable, Sendable, Identifiable {
    public var id: String
    public var ip: String
    public var version: String
    public var productKey: String?
}

/// Finds Tuya devices on your Wi-Fi from the UDP broadcasts they send every few seconds
/// (port 6666 plaintext, 6667 encrypted with the well-known Tuya UDP key).
public enum TuyaDiscovery {
    /// Listens for `seconds` and returns everything heard, newest first.
    public static func scan(seconds: TimeInterval = 6) async -> [DiscoveredDevice] {
        await Task.detached(priority: .utility) { listen(seconds: seconds) }.value
    }

    static func listen(seconds: TimeInterval) -> [DiscoveredDevice] {
        let sockets = [6666, 6667].compactMap(openSocket)
        defer { sockets.forEach { close($0) } }
        guard !sockets.isEmpty else { return [] }
        var found: [String: DiscoveredDevice] = [:]
        let deadline = Date().addingTimeInterval(seconds)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var fds = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ms = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard poll(&fds, nfds_t(fds.count), ms) > 0 else { continue }
            for p in fds where p.revents & Int16(POLLIN) != 0 {
                let n = recv(p.fd, &buf, buf.count, 0)
                guard n > 0, let dev = parse(Data(buf[0..<n])) else { continue }
                found[dev.id] = dev
            }
        }
        return Array(found.values)
    }

    private static func openSocket(_ port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }

    /// Decodes one broadcast packet.
    static func parse(_ packet: Data) -> DiscoveredDevice? {
        var json: Data?
        if packet.first == UInt8(ascii: "{") {
            json = packet
        } else if packet.count >= 4, packet.uint32(at: 0) == FrameCodec.prefix6699 {
            json = try? FrameCodec.decode(packet, version: .v35, key: TuyaCrypto.udpKey, hasRetcode: nil).payload
        } else if packet.count >= 4, packet.uint32(at: 0) == FrameCodec.prefix55AA {
            json = try? FrameCodec.decode(packet, version: .v33, key: TuyaCrypto.udpKey, hasRetcode: true).payload
        } else {
            json = try? TuyaCrypto.ecbDecrypt(packet, key: TuyaCrypto.udpKey)
        }
        guard var raw = json else { return nil }
        while raw.last == 0 { raw.removeLast() }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let id = obj["gwId"] as? String, let ip = obj["ip"] as? String else { return nil }
        return DiscoveredDevice(id: id, ip: ip, version: obj["version"] as? String ?? "3.3", productKey: obj["productKey"] as? String)
    }
}
